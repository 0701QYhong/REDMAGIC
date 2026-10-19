#!/system/bin/sh
# ============================================================
# 基础设施：读节点、读写记忆、日志。
# 约定：本文件只提供原语，不含任何业务判断。
# ============================================================

# ---------------- 读节点 ----------------
# rd PATH：路径不存在则返回 1；结果写全局 RD，不 echo。
# 状态快照一秒要读十几个节点，dd 每次 fork 约 20ms，所以用内建定长读取。
# 不能写普通 read：micropump/speed 这类 proc 节点每次 read() 只返回 1 字节，
# 普通 read 会把 "90" 读成 "9"。read -N 会持续读到 EOF 或满 64 字节。
rd() {
    RD=""
    [ -e "$1" ] || return 1
    IFS= read -rN 64 RD 2>/dev/null < "$1"
    [ -n "$RD" ] || RD=$(dd if="$1" bs=64 count=1 2>/dev/null)
    case "$RD" in *'
'*) RD=${RD%%'
'*};; esac
    return 0
}

# rdv PATH：读节点并剥掉空白，只 echo 值（不碰全局 RD，也不碰调用方自己的变量）
rdv() {
    [ -e "$1" ] || return 1
    local v=""
    IFS= read -rN 64 v 2>/dev/null < "$1"
    if [ -z "$v" ]; then
        v=$(dd if="$1" bs=64 count=1 2>/dev/null)
    fi
    case "$v" in *'
'*) v=${v%%'
'*};; esac
    printf '%s' "$v"
}

# wr PATH VALUE：写节点（失败返回非 0）
wr() {
    printf '%s\n' "$2" > "$1" 2>/dev/null
}

# ---------------- 记忆（state.txt）----------------
# cfg KEY：读 config.txt 的默认值；st KEY：读用户记忆 state.txt
# 只写全局 CFGV / STV，不输出 —— 调用方一律读变量，别用 $(cfg ...) / $(st ...)
CFGV=""
STV=""
cfg() { CFGV=$(grep -o "^$1=.*" "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r'); return 0; }
st()  { STV=$(grep -o "^$1=.*" "$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r'); return 0; }
# stq KEY / cfgq KEY / stgq ARGS...：$( ) 里取值用这几个（在子 shell 里跑，直接 echo 结果）
stq()  { grep -o "^$1=.*" "$STATE_FILE"  2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r'; }
cfgq() { grep -o "^$1=.*" "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r'; }
stgq() {
    local _i=1 _o=""
    while [ "$_i" -le 3 ]; do
        _o=$($SETTINGS_TO settings "$@" 2>/dev/null)
        case "$_o" in
            "") sleep 1; _i=$((_i + 1)); continue;;
        esac
        printf '%s' "$_o"
        return 0
    done
    return 1
}

# cfg_set KEY VALUE：原子写。绝不写空，避免并发把文件截断。
cfg_set() {
    [ -n "$1" ] || return 1
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
    local esc tmp
    # sed 里 / 和 & 需转义；值里出现换行视为非法
    esc=$(printf '%s' "$2" | tr -d '\n' | sed -e 's/[\\/&]/\\&/g')
    tmp=$(mktemp "$STATE_FILE.XXXXXX" 2>/dev/null) || return 1
    sed "s/^$1=.*/$1=$esc/" "$STATE_FILE" > "$tmp" 2>/dev/null
    grep -q "^$1=" "$tmp" 2>/dev/null || printf '%s=%s\n' "$1" "$2" >> "$tmp"
    # 空文件不落地：宁可这次没写，也不能让 state.txt 变成 0 字节
    [ -s "$tmp" ] && mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    [ -s "$STATE_FILE" ]
}

# state_repair：config.txt 有、state.txt 缺的键补回来（升级/手删后自愈）
state_repair() {
    [ -f "$CONFIG_FILE" ] || return 1
    local n=0 line k v
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue;; *=*) ;; *) continue;; esac
        k=${line%%=*}
        v=${line#*=}
        grep -q "^$k=" "$STATE_FILE" 2>/dev/null && continue
        printf '%s=%s\n' "$k" "$v" >> "$STATE_FILE"
        n=$((n + 1))
    done < "$CONFIG_FILE"
    [ "$n" -gt 0 ] && mlog "state.txt: 补回 $n 个缺失键（值取 config.txt）"
    return 0
}

# ---------------- 日志 ----------------
LOG_BLOCK=""
mlog_rotate() {
    [ -f "$LOG_FILE" ] || return 0
    local sz
    sz=$(($(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)))
    [ "$sz" -gt 1048576 ] 2>/dev/null || return 0
    mv -f "$LOG_FILE" "$LOG_PREV" 2>/dev/null
    tail -n 1600 "$LOG_PREV" > "$LOG_FILE" 2>/dev/null
}
mlog_block_on() { LOG_BLOCK=1; }
mlog_block_off() {
    [ -n "$LOG_BLOCK" ] || return 0
    printf '%s' "$LOG_BLOCK" >> "$LOG_FILE" 2>/dev/null
    LOG_BLOCK=""
}
# mlog MSG：默认每行直接落盘；mlog_block_on 后攒在内存里一次写（省 IO）
mlog() {
    local ts line
    ts=$(date '+%m-%d %H:%M:%S' 2>/dev/null)
    line="[$ts] $*"
    if [ -n "$LOG_BLOCK" ]; then
        LOG_BLOCK="$LOG_BLOCK$line$NL"
    else
        printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null
    fi
}
# errlog MSG：写一份到 .last_error，前端点「日志」时能看到失败原因
errlog() {
    mlog "[FAIL] $*"
    printf '%s %s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$ERRLOG" 2>/dev/null
}

# ---------------- settings ----------------
SETTINGS_TO="timeout 3"
# stg ARGS...：settings 包装。系统刚起时 service 可能还没注册，重试 3 次。
# stg ARGS...：settings 取值的加固版。
# 成功时静默返回 0，值只写进全局 STG_OUT（不 echo）；失败返回 1 并带原因。
# 以前用 $(stg ...) 取值，拿到的是被吞掉一句提示后的结果，踩过坑，改成全局变量。
STG_OUT=""
stg() {
    local i=1 out=""
    STG_OUT=""
    while [ "$i" -le 3 ]; do
        out=$($SETTINGS_TO settings "$@" 2>&1)
        case "$out" in
            *"Failure calling service settings"*) sleep 1; i=$((i + 1)); continue;;
        esac
        STG_OUT="$out"
        return 0
    done
    echo "settings 读取失败: $*"
    return 1
}

# ---------------- 标记 ----------------
f_on() { [ -f "$1" ]; }
f_set() { : > "$1" 2>/dev/null; }
f_del() { rm -f "$1" 2>/dev/null; }
