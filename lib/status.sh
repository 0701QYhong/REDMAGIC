#!/system/bin/sh
# ============================================================
# 状态快照：每行一条 key=value，前端 500ms 读一次。
# 只读不写模块以外的东西；外部读到的字符串一律过 kv_safe。
# 约定：字段缺失 = 前端保留上一份，字段为 0/空 = 明确不可用。
# 值里绝不允许出现换行（前端按行切），所以所有外部字符串都过一遍清洗。
# ============================================================

HB_FRESH=30

# 单行化 + 去掉大写标记字符（前端解析键名时不区分大小写，容易撞）；过长直接截断
kv_safe() {   # VALUE DEFAULT
    local v d
    v=$(printf '%s' "$1" | tr -d '\r\n' | tr -d '"\\')
    d=$(printf '%s' "$2" | tr -d '\r\n' | tr -d '"\\')
    [ ${#v} -le 200 ] || v="$d"
    printf '%s' "$v"
}
kv_num() {    # VALUE DEFAULT —— 只留整数
    case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
# 带一位小数的数值（百分号以外的字符一律剔除）
kv_dec() {    # VALUE DEFAULT
    case "$1" in '') printf '%s' "$2" ;; esac
    case "$1" in ''|*[!0-9.]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
flag_int() { [ -f "$1" ] && printf '1' || printf '0'; }
bool_int() { [ -n "$1" ] && [ "$1" != "0" ] && printf '1' || printf '0'; }

stat_age() {
    local m now
    [ -f "$WEBUI_STATUS" ] || { printf '999999'; return 0; }
    m=$(stat -c %Y "$WEBUI_STATUS" 2>/dev/null)
    now=$(date +%s 2>/dev/null)
    case "$m" in ''|*[!0-9]*) printf '999999'; return 0;; esac
    case "$now" in ''|*[!0-9]*) printf '999999'; return 0;; esac
    printf '%s' $((now - m))
}

hb_state() {
    local age
    age=$(stat_age)
    if [ "$age" -le "$HB_FRESH" ] 2>/dev/null; then printf '1'; else printf '0'; fi
}

# 模块健康：状态码 2=正常 1=部分功能挂 0=核心挂
# load 只写全局；module_state 保留原来的 "状态码 失效项" 输出接口。
MODULE_STATE=""
MODULE_STATE_FAIL=""
module_state_load() {
    local fail="" pid
    # 先把两个动态项拍成普通变量，后面只做字符串判断：
    # 直接写 "cmd && ! cmd2 && fail=..." 会踩 set -e 与 && 链的坑，且不容易读。
    local te=0 tm=""
    thermal_effective && te=1
    tm=$(touch_missing_nodes 2>/dev/null)
    if [ -f "$SVC_PID_FILE" ]; then
        pid=$(cat "$SVC_PID_FILE" 2>/dev/null)
        case "$pid" in ''|*[!0-9]*) fail="svc";; *) [ -d "/proc/$pid" ] || fail="svc";; esac
    else
        fail="svc"
    fi
    if [ -n "$fail" ]; then MODULE_STATE=0; MODULE_STATE_FAIL="$fail"; return 0; fi
    # 核心还活着，才继续看各功能有没有失效（失效只算"部分异常"）
    if [ -f "$F_BOOST" ] && [ "$te" = "0" ]; then fail="$fail thermal"; fi
    if [ -f "$F_TOUCH" ] && [ "$tm" != "0" ]; then fail="$fail touch"; fi
    # 风扇开关为 0 是"已开启、等系统打开"的正常等待态，不算故障。
    case "$fail" in
        "") MODULE_STATE=2; MODULE_STATE_FAIL="" ;;
        *) MODULE_STATE=1; MODULE_STATE_FAIL="${fail# }" ;;
    esac
    return 0
}
module_state() {
    module_state_load
    printf '%s %s' "$MODULE_STATE" "$MODULE_STATE_FAIL"
}

# 触控序列化只保留 lib/touch.sh 里的一份实现。
# status.sh 在 touch.sh 之后 source，以前这里重复定义把修好的版本又盖回去了。

# 生成快照（调用方负责写到 .tmp 再 mv）
status_body() {
    local cap="" t="" cur="" vol="" power="0" ac=0 usb=0 fan_en=0 charge_on=0
    local cs="0" thr="" fan_lv="" fan_saved="" fan_avail=0 pump_lv="" pump_saved="" pump_avail=0 bl="" blm="" blg=""
    local tm="" tmiss="" tpreset="" tvals="" blgs=""
    local rate_v="0" rate_cap="" rate_tgt="0" be=0 mf te=0 i
    local fan_on=0 pump_on=0 fan_keep=0 pump_keep=0 fan_temp=0 pump_temp=0
    local thermal_on=0 boost_on=0 boost_heat=0 bright_on=0 bright_avail=1 touch_on=0 rate_on=0
    local ftthr=40 ptthr=40 boost_thr=42 bl_cur=0 bl_max=0 bl_goal=0
    # 一次读完 state.txt：下面十几项记忆值都从变量取，不再逐项 fork grep
    state_load

    # ---- 电池 ----
    rd "$BAT_DIR/capacity"; cap="$RD"
    case "$cap" in ''|*[!0-9]*) cap=0;; esac
    rd "$BAT_DIR/temp"; t="$RD"
    case "$t" in ''|*[!0-9-]*) t=0;; esac
    rd "$BAT_DIR/current_now"; cur="$RD"
    rd "$BAT_DIR/voltage_now"; vol="$RD"
    case "$cur" in ''|*[!0-9-]*) cur="";; esac
    case "$vol" in ''|*[!0-9-]*) vol="";; esac
    if [ -n "$cur" ] && [ -n "$vol" ]; then
        # uA * uV = pW；/1e11 → 0.1W 单位，再拼出一位小数
        cur=${cur#-}; vol=${vol#-}
        i=$(( cur * vol / 100000000000 ))
        power="$(( i / 10 )).$(( i % 10 ))"
    fi
    ac=$(bool_int "$(rdv "$AC_ONLINE")")
    usb=$(bool_int "$(rdv /sys/class/power_supply/usb/online)")

    # ---- 充电分离 ----
    # 分离开关由 patrol 维护并落缓存，状态快照读缓存，避免每轮 fork settings
    rd "$SEP_CACHE"; cs="$RD"
    case "$cs" in 0|1) ;; *) cs=$(sep_now);; esac
    thr=$ST_SEP_THR
    case "$thr" in ''|*[!0-9]*) thr=100;; esac
    { [ "$thr" -ge 20 ] && [ "$thr" -le 100 ]; } 2>/dev/null || thr=100

    # ---- 风扇 / 液冷 ----
    if [ -e "$FAN_LEVEL" ]; then
        fan_avail=1
        rd "$FAN_LEVEL"
        case "$RD" in ''|*[!0-9]*) ;; *) fan_lv="$RD" ;; esac
    fi
    fan_saved=$ST_FAN
    case "$fan_saved" in 1|2|3|4|5) ;; *) fan_saved="";; esac
    if [ -e "$PUMP_SPEED" ]; then
        pump_avail=1
        rd "$PUMP_SPEED"
        case "$RD" in 40) pump_lv=1;; 60) pump_lv=2;; 80) pump_lv=3;; 90) pump_lv=4;; esac
    fi
    pump_saved=$ST_PUMP
    case "$pump_saved" in 1|2|3|4) ;; *) pump_saved="";; esac
    rd "$FAN_ENABLE"; fan_en=$(bool_int "$RD")

    # ---- 采样率 ----
    # 采样率只在模块写入或看门狗核对时刷新缓存
    rd "$RATE_CACHE"; rate_v="$RD"
    case "$rate_v" in ''|*[!0-9]*) rate_v=$(rate_current);; esac
    rate_cap=$ST_RCAP
    case "$rate_cap" in ''|*[!0-9]*) rate_cap="";; esac
    if [ -n "$rate_cap" ]; then
        rate_tgt=$rate_cap
    else
        rate_gear_scan
        rate_tgt=$rate_v
        [ "$RATE_GEAR" -gt "$rate_tgt" ] 2>/dev/null && rate_tgt=$RATE_GEAR
        [ "$rate_tgt" -ge 60 ] 2>/dev/null || rate_tgt=$RATE_FALLBACK
    fi

    # ---- 温控（只问一次，它有 1 秒缓存）----
    thermal_effective && te=1

    # ---- 亮度 ----
    if bright_nodes 2>/dev/null; then
        rd "$BL_BRIGHT"; bl="$RD"
        [ -n "$BL_MAX" ] && [ -e "$BL_MAX" ] && { rd "$BL_MAX"; blm="$RD"; }
    fi
    case "$bl" in ''|*[!0-9]*) bl="";; esac
    case "$blm" in ''|*[!0-9]*) blm="";; esac
    if [ -n "$bl" ]; then
        blg=$ST_BGOAL
        case "$blg" in ''|*[!0-9]*) blg=8190;; esac
        [ -n "$blm" ] && [ "$blg" -gt "$blm" ] 2>/dev/null && blg=$blm
    else
        blg=""
    fi
    blgs=$ST_BGOAL
    case "$blgs" in ''|*[!0-9]*) blgs="";; esac

    # ---- 触控 ----
    touch_missing_nodes >/dev/null
    tmiss=$TOUCH_MISSING
    touch_vals_build
    tvals=$TOUCH_VALS
    tpreset=$ST_TP
    case "$tpreset" in official_gaming|official_daily) ;; *) tpreset="official_gaming";; esac
    # 与所选预设的定义逐项比对：全一致才算 preset，否则算用户手调 manual
    tm="manual"
    touch_preset_build "$tpreset"
    if [ -n "$tvals" ] && [ "$tvals" = "$TOUCH_PRESET_VALS" ]; then tm="preset"; fi

    # ---- 模块健康 ----
    module_state_load
    mf=$MODULE_STATE_FAIL
    [ -f "$F_BOOST" ] && boost_effective && be=1

    # ---- 开关与输出：echo 是 mksh 内建，printf 在 Android 上会 fork toybox ----
    [ -f "$F_FAN" ] && fan_on=1
    [ -f "$F_PUMP" ] && pump_on=1
    [ -f "$F_CHARGE" ] && charge_on=1
    [ -f "$F_FAN_KEEP" ] && fan_keep=1
    [ -f "$F_PUMP_KEEP" ] && pump_keep=1
    [ -f "$F_FAN_TEMP" ] && fan_temp=1
    [ -f "$F_PUMP_TEMP" ] && pump_temp=1
    [ -f "$F_THERMAL" ] && thermal_on=1
    [ -f "$F_BOOST" ] && boost_on=1
    [ -f "$F_BOOST_HEAT" ] && boost_heat=1
    [ -f "$F_BRIGHT" ] && bright_on=1
    [ -f "$BRIGHT_NA" ] && bright_avail=0
    [ -f "$F_TOUCH" ] && touch_on=1
    [ -f "$F_RATE" ] && rate_on=1
    case "$ST_FAN_THR" in ''|*[!0-9]*) ;; *) ftthr=$ST_FAN_THR ;; esac
    case "$ST_PUMP_THR" in ''|*[!0-9]*) ;; *) ptthr=$ST_PUMP_THR ;; esac
    case "$bl" in ''|*[!0-9]*) ;; *) bl_cur=$bl ;; esac
    case "$blm" in ''|*[!0-9]*) ;; *) bl_max=$blm ;; esac
    case "$blg" in ''|*[!0-9]*) ;; *) bl_goal=$blg ;; esac
    boost_thr=$ST_BOOST_THR
    case "$boost_thr" in ''|*[!0-9]*) boost_thr=42;; esac
    { [ "$boost_thr" -ge 20 ] && [ "$boost_thr" -le 70 ]; } 2>/dev/null || boost_thr=42

    # ---- 输出 ----
    echo "battery=$cap"
    echo "temp_deg=$(( t / 10 )).$(( (t % 10 + 10) % 10 ))"
    echo "power=$power"
    echo "ac=$ac"
    echo "usb=$usb"
    echo "cs=$cs"
    echo "charge_on=$charge_on"
    echo "threshold=$thr"
    echo "fan_available=$fan_avail"
    echo "fan_level=$fan_lv"
    echo "fan_level_saved=$fan_saved"
    echo "fan_on=$fan_on"
    echo "fan_enabled=$fan_en"
    echo "pump_available=$pump_avail"
    echo "pump_level=$pump_lv"
    echo "pump_level_saved=$pump_saved"
    echo "pump_on=$pump_on"
    echo "fan_keep=$fan_keep"
    echo "pump_keep=$pump_keep"
    echo "fan_temp_ctrl=$fan_temp"
    echo "fan_temp_mode=$ST_FAN_MODE"
    echo "fan_temp_thr=$ftthr"
    echo "pump_temp_ctrl=$pump_temp"
    echo "pump_temp_mode=$ST_PUMP_MODE"
    echo "pump_temp_thr=$ptthr"
    echo "thermal_on=$thermal_on"
    echo "thermal_effective=$te"
    echo "boost_on=$boost_on"
    echo "boost_ready=$be"
    echo "boost_thr=$boost_thr"
    echo "boost_heat=$boost_heat"
    echo "bright_on=$bright_on"
    echo "bright_available=$bright_avail"
    echo "bright_cur=$bl_cur"
    echo "bright_max=$bl_max"
    echo "bright_goal=$bl_goal"
    echo "bright_goal_set=$blgs"
    echo "touch_on=$touch_on"
    echo "touch_missing=$tmiss"
    echo "touch_preset=$tpreset"
    echo "touch_mode=$tm"
    echo "touch_vals=$tvals"
    echo "rate_on=$rate_on"
    echo "rate_value=$rate_v"
    echo "rate_max=$rate_cap"
    echo "rate_target=$rate_tgt"
    echo "rate_avail=1"
    echo "module_state=$MODULE_STATE"
    echo "module_fail=$mf"
}

# 写快照：先 .tmp 再 mv（前端永远读不到半份），并落下心跳门控标记
status_write() {
    status_body > "$WEBUI_STATUS.tmp" 2>/dev/null || return 1
    [ -s "$WEBUI_STATUS.tmp" ] || return 1
    mv -f "$WEBUI_STATUS.tmp" "$WEBUI_STATUS" 2>/dev/null || return 1
    : > "$WEBUI_HB_SEEN" 2>/dev/null
    return 0
}
