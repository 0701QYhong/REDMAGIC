#!/system/bin/sh
# ============================================================
# 系统级原语：写受保护节点并精确还原权限、屏幕状态、电池读数。
# 铁律：任何一次放宽权限，必须在同一个函数里立刻收回。
# ============================================================

# 快照一个节点的原值与原权限，追加到快照文件
# 注意：不能在函数里用 local 声明叫 v/m 之外的通用名，但更不能把 printf 拆成多行 ——
# printf 的参数必须和格式串在同一条语句里，跨行写会只输出半行（踩过）。
snap_node() {   # snap_node SNAPFILE KEY NODE
    local f="$1" k="$2" n="$3" val md
    [ -e "$n" ] || return 0
    rd "$n"; val="$RD"
    md=$(stat -c %a "$n" 2>/dev/null)
    printf '%s_v=%s\n%s_mode=%s\n' "$k" "$val" "$k" "$md" >> "$f" 2>/dev/null
}

# 从快照取一个字段
snap_get() {    # snap_get SNAPFILE KEY
    local f="$1" k="$2"
    [ -f "$f" ] || return 1
    grep -o "^$k=.*" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# 写节点：若当前权限挡住写入就临时 644，写完无条件还原原权限。
# 返回写入的退出码（不是 chmod 的）。
node_write() {  # node_write NODE VALUE ORIG_MODE
    local n="$1" v="$2" om="$3"
    [ -e "$n" ] || return 1
    case "$om" in ''|*[!0-7]*) om=$(stat -c %a "$n" 2>/dev/null);; esac
    case "$om" in ''|*[!0-7]*) om=444;; esac
    chmod 644 "$n" 2>/dev/null
    printf '%s\n' "$v" > "$n" 2>/dev/null
    local rc=$?
    chmod "$om" "$n" 2>/dev/null
    return $rc
}

# 同上，但节点属 system（风扇 enable 等）：先自己写，不行再 su 2000 代写。
# 无论 su 是否跑完，外层 root 都会按原权限再收一次（双保险）。
node_write_su() {   # node_write_su NODE VALUE ORIG_MODE
    local n="$1" v="$2" om="$3" cur
    [ -e "$n" ] || return 1
    case "$om" in ''|*[!0-7]*) om=$(stat -c %a "$n" 2>/dev/null);; esac
    case "$om" in ''|*[!0-7]*) om=444;; esac
    node_write "$n" "$v" "$om" && return 0
    su 2000 -c "chmod 644 '$n' 2>/dev/null; printf '%s\\n' '$v' > '$n' 2>/dev/null; chmod $om '$n' 2>/dev/null" 2>/dev/null
    local rc=$?
    cur=$(stat -c %a "$n" 2>/dev/null)
    [ "$cur" = "$om" ] || chmod "$om" "$n" 2>/dev/null
    return $rc
}

# ---------------- 屏幕 ----------------
# 每轮只查一次，结果缓存到 SCREEN_AT/SCREEN_VAL
SCREEN_AT=""
SCREEN_VAL=""
screen_state() {
    local t o f
    t=$(date +%s 2>/dev/null)
    if [ -n "$SCREEN_AT" ] && [ "$t" = "$SCREEN_AT" ] && [ -n "$SCREEN_VAL" ]; then
        printf '%s' "$SCREEN_VAL"
        return 0
    fi
    SCREEN_AT="$t"
    SCREEN_VAL=""
    o=$(dumpsys power 2>/dev/null | grep -m1 -E 'mWakefulness=|mScreenOn=')
    case "$o" in
        *mWakefulness=Awake*) SCREEN_VAL="awake" ;;
        *mWakefulness=Asleep*|*mWakefulness=Dozing*) SCREEN_VAL="asleep" ;;
        *mScreenOn=true*) SCREEN_VAL="awake" ;;
        *mScreenOn=false*) SCREEN_VAL="asleep" ;;
    esac
    if [ -z "$SCREEN_VAL" ]; then
        for f in /sys/class/backlight/*/brightness; do
            [ -e "$f" ] || continue
            rd "$f"
            case "$RD" in
                ''|*[!0-9]*) ;;
                0) SCREEN_VAL="asleep" ;;
                *) SCREEN_VAL="awake" ;;
            esac
            [ -z "$SCREEN_VAL" ] || break
        done
    fi
    [ -n "$SCREEN_VAL" ] || SCREEN_VAL="unknown"
    printf '%s' "$SCREEN_VAL"
}

# ---------------- 电池 ----------------
battery_temp_deg() {
    rd "$BAT_DIR/temp" || return 1
    case "$RD" in ''|*[!0-9-]*) return 1;; esac
    echo $((RD / 10))
}
# ---------------- 采样率 ----------------
# 触控采样率没有独立内核节点，走 settings system touch_sampling_rate。
# 目标值优先级：用户填的「采样率上限」> 机型 gear 上限 > 960。
RATE_FALLBACK=960
RATE_GEAR_PROP=ro.vendor.feature.zte_touch_rate_gear_configuration

# 注意用 stgq：stg 成功时只写全局 STG_OUT，不 echo，直接 $(stg get ...) 永远拿到空串
rate_raw() { stgq get system touch_sampling_rate 2>/dev/null; }
rate_current() {
    local v
    v=$(rate_raw)
    case "$v" in
        ''|null|*[!0-9]*) v=0 ;;
    esac
    printf '%s\n' "$v" > "$RATE_CACHE" 2>/dev/null
    printf '%s' "$v"
}
# gear 配置是逗号分隔的档位列表（NX809J 实测 "480,960"），不是单个数字。
# 以前整串当数字解析失败 → 回落 960，反而把系统原本的 1440 降下去了。
RATE_GEAR=""
rate_gear_scan() {
    [ -n "$RATE_GEAR" ] && return 0
    local v one max=0
    v=$(getprop "$RATE_GEAR_PROP" 2>/dev/null | tr ',' ' ')
    for one in $v; do
        case "$one" in ''|*[!0-9]*) continue;; esac
        [ "$one" -gt "$max" ] 2>/dev/null && max=$one
    done
    RATE_GEAR=$max
}
rate_gear_max() {
    rate_gear_scan
    printf '%s' "$RATE_GEAR"
}

RATE_TARGET=""
# 只算目标，不再额外读 settings：调用方已经读过当前值时直接传进来
rate_target_calc() {   # CURRENT
    local u g c
    u=$(stq '采样率上限')
    case "$u" in ''|*[!0-9]*) u="";; esac
    if [ -n "$u" ] && [ "$u" -ge 60 ] 2>/dev/null && [ "$u" -le 2400 ] 2>/dev/null; then
        printf '%s' "$u"
        return 0
    fi
    g=$(rate_gear_max)
    case "$g" in ''|*[!0-9]*) g=0;; esac
    c="$1"
    case "$c" in ''|*[!0-9]*) c=0;; esac
    { [ "$c" -ge 60 ] && [ "$c" -le 2400 ]; } 2>/dev/null || c=0
    # 没填上限时取「当前值 / 档位上限」里较大的一个，绝不主动降采样率
    [ "$g" -gt "$c" ] 2>/dev/null && c=$g
    [ "$c" -ge 60 ] 2>/dev/null || c=$RATE_FALLBACK
    printf '%s' "$c"
}
rate_target_set() { RATE_TARGET=$(rate_target_calc "$(rate_current)"); printf '%s' "$RATE_TARGET"; }
rate_target() { rate_target_set; }

rate_boost_on() {
    local t cur raw
    raw=$(rate_raw)
    # 读不到系统值（settings 服务没起）就先不写，避免拿 0 去猜目标把 1440 降到 960
    case "$raw" in '') errlog "采样率: 读取系统值失败，暂不写入"; return 1;; esac
    t=$(rate_target)
    # 第一次接管前记下系统原值（可能是 null），关闭时原样还回去
    if [ ! -f "$RATE_SNAPSHOT" ]; then
        cur=$(stgq get system touch_sampling_rate 2>/dev/null)
        case "$cur" in '') cur="null";; esac
        printf '%s\n' "$cur" > "$RATE_SNAPSHOT" 2>/dev/null
    fi
    [ "$(rate_current)" = "$t" ] && return 0
    stg put system touch_sampling_rate "$t" >/dev/null 2>&1
    [ "$(rate_current)" = "$t" ] && return 0
    errlog "采样率: 写入 $t 失败"
    return 1
}

# 开机时 settings 服务可能还没起来，重试若干次（原放主链会阻塞开机 12 秒）
rate_boost_boot() {
    local i=1
    while [ "$i" -le 6 ]; do
        rate_boost_on && return 0
        sleep 2
        i=$((i + 1))
    done
    return 1
}

rate_boost_off() {
    local v
    # 没接管过就不动系统设置；接管过就还原原值，原值是 null 才删除
    [ -f "$RATE_SNAPSHOT" ] || return 0
    v=$(cat "$RATE_SNAPSHOT" 2>/dev/null | tr -d '\r\n')
    case "$v" in
        ''|null) stg delete system touch_sampling_rate >/dev/null 2>&1 ;;
        *[!0-9]*) : ;;
        *) stg put system touch_sampling_rate "$v" >/dev/null 2>&1 ;;
    esac
    rm -f "$RATE_SNAPSHOT" 2>/dev/null
    rate_current >/dev/null 2>&1
    return 0
}

rate_verify() {
    local cur
    cur=$(rate_current)
    [ "$cur" = "$(rate_target)" ]
}

battery_capacity() {
    rd "$BAT_DIR/capacity" || return 1
    case "$RD" in ''|*[!0-9]*) return 1;; esac
    printf '%s' "$RD"
}
