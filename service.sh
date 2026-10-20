#!/system/bin/sh
# ============================================================
# REDMAGIC 主服务。开机由 KernelSU 以 root 拉起，只允许跑一份。
# 失败一律落日志 + 回滚记忆，绝不让界面显示一个不成立的状态。
# ============================================================
MODDIR=${0%/*}
[ -d "$MODDIR" ] || exit 1
cd "$MODDIR" 2>/dev/null || true

. "$MODDIR/paths.sh"
. "$MODDIR/common.sh"
for _f in system thermal fanpump charge touch bright state commands status loop teardown; do
    . "$MODDIR/lib/$_f.sh"
done

WEBUI_STALE_MAX=45
DAEMONS=""
CLEANED=""
SVC_SELF=$$
BRIGHT_PID=""
WEBUI_PID=""

# ---------------- 单实例 ----------------
svc_alive() {
    [ -n "$1" ] || return 1
    [ -d "/proc/$1" ] || return 1
    tr -d '\000' < "/proc/$1/cmdline" 2>/dev/null | grep -q "$SVC_CMDLINE_PAT"
}

if [ -f "$SVC_LOCK_FILE" ]; then
    _lock=$(cat "$SVC_LOCK_FILE" 2>/dev/null)
    if svc_alive "$_lock"; then
        printf '%s\n' "$(date '+%m-%d %H:%M:%S') 已有实例 $_lock 在跑" >> "$LOG_FILE" 2>/dev/null
        exit 0
    fi
fi
( set -C; printf '%s\n' "$$" > "$SVC_LOCK_FILE" ) 2>/dev/null || {
    _lock=$(cat "$SVC_LOCK_FILE" 2>/dev/null)
    svc_alive "$_lock" && exit 0
    rm -f "$SVC_LOCK_FILE" 2>/dev/null
    printf '%s\n' "$$" > "$SVC_LOCK_FILE"
}
printf '%s\n' "$$" > "$SVC_PID_FILE"

cleanup() {
    # 只清理一次：TERM 和 EXIT 都会进来，靠标记防重入
    [ -n "$CLEANED" ] && return 0
    CLEANED=1
    local p
    for p in $DAEMONS; do kill "$p" 2>/dev/null; done
    sleep 1 2>/dev/null
    for p in $DAEMONS; do kill -9 "$p" 2>/dev/null; done
    rm -f "$SVC_PID_FILE" "$SVC_LOCK_FILE" 2>/dev/null
}
# 旧写法在 cleanup 里 trap '' TERM，TERM 处理完后又回到主循环，
# 进程从此无视 TERM 只能 kill -9。这里处理完必须真正退出。
on_term() { cleanup; exit 0; }
trap on_term TERM INT HUP
trap cleanup EXIT

# ---------------- 初始化 ----------------
mlog_rotate
: > "$ERRLOG" 2>/dev/null
: > "$WEBUI_HB_SEEN" 2>/dev/null
rm -f "$BRIGHT_NA" "$WEBUI_HB" "$WEBUI_STATUS" 2>/dev/null
rm -f "$SEP_CACHE" "$RATE_CACHE" 2>/dev/null

state_repair
state_restore_flags
seed_values

mlog "===== 开机 $(grep '^version=' module.prop 2>/dev/null | cut -d= -f2) ====="
mlog "机型 $(getprop ro.product.model 2>/dev/null) / Android $(getprop ro.build.version.release 2>/dev/null) / 内核 $(uname -r 2>/dev/null)"

# 采样率：写得越早触控初始化越容易吃到。settings 服务可能还没起，
# rate_boost_boot 会重试 6 次（最坏 12 秒），所以放后台，绝不阻塞开机主链
if [ -f "$F_RATE" ]; then
    ( rate_boost_boot; sleep 15 ) &
fi

# 温控屏蔽：必须在充电加速之前
# 注意标记是 F_THERMAL。以前这里写的是 F_CHARGE（充电分离），
# 结果只勾「充电分离」也会去 bind 空 thermal-engine.conf 并 chmod 全部 cpufreq。
if [ -f "$F_THERMAL" ]; then
    thermal_on || { rm -f "$F_THERMAL"; cfg_set '温控移除' 0; }
fi
if [ -f "$F_BOOST" ] && ! thermal_effective; then
    rm -f "$F_BOOST"; cfg_set '充电加速' 0
    mlog "充电加速: 温控未生效，本次开机不开加速"
fi
if [ -f "$F_BOOST" ]; then
    # 开机也必须过守卫：以前直接 boost_apply，温度/分离条件没检查就解限流
    if boost_guard; then
        boost_apply || mlog "充电加速: 开机应用失败，交给 reconcile 重试"
    else
        mlog "充电加速: 开机条件未满足，等待自动生效"
    fi
fi
[ -f "$F_BOOST_HEAT" ] && { heat_apply || { rm -f "$F_BOOST_HEAT"; cfg_set '解除热降流' 0; }; }

# 触控：节点可能还没就绪，放后台等（不阻塞主链）
if [ -f "$F_TOUCH" ]; then
    ( TOUCH_WAIT_MAX=20; touch_apply; sleep 15 ) &
fi

# 亮度：同样后台等背光节点
if [ -f "$F_BRIGHT" ]; then
    bright_daemon &
    BRIGHT_PID=$!
fi

# 风扇 / 液冷：按记忆接管；系统没开就等它开（reconcile 会补）
if [ -f "$F_FAN" ]; then
    if fan_sys_on; then fan_level_write "$(stq '风扇档位')"; else mlog "风扇: 系统开关为关，等待"; fi
fi
if [ -f "$F_PUMP" ]; then
    if pump_sys_on; then pump_speed_write "$(pump_speed_of "$(stq '液冷档位')")"; else mlog "液冷: 系统开关为关，等待"; fi
fi

# ---------------- 守护 ----------------
# 充电分离巡逻：插电且电量达到阈值 -> 系统开关置 1，否则置 0
charge_sep_patrol() {
    local last="" want cap
    while :; do
        # $$ 在 mksh 后台函数里仍是 service 的 PID，service 没了就自行退出
        [ -d "/proc/$SVC_SELF" ] || exit 0
        if [ -f "$F_CHARGE" ]; then
            want=0
            if [ "$(rdv "$AC_ONLINE" 2>/dev/null)" = "1" ]; then
                cap=$(battery_capacity) || cap=0
                [ "$cap" -ge "$(sep_limit)" ] 2>/dev/null && want=1
            fi
            # 除了目标变化，系统开关被外部改掉（或手动关开太快）也要拉回目标值
            if [ "$want" != "$last" ] || [ "$(sep_now)" != "$want" ]; then
                charge_sep_set "$want"
                mlog "充电分离: $([ "$want" = 1 ] && echo 开启 || echo 关闭)（电量 ${cap}% / 阈值 $(sep_limit)%）"
                last=$want
            fi
        elif [ "$last" != "0" ]; then
            [ "$(sep_now)" = "1" ] && stg put global charge_separation_switch 0 >/dev/null 2>&1
            sep_store 0
            sep_init
            last="0"
        fi
        sleep 3
    done
}

charge_sep_patrol &
SEP_PID=$!
webui_loop &
WEBUI_PID=$!
# 只登记常驻进程。一次性的初始化子进程（触控首写/亮度守护/采样率重试）不登记，
# 否则它们跑完退出后再来一次 TERM 就会撞上被复用的 PID，误杀无关进程。
DAEMONS="$SEP_PID $WEBUI_PID"

mlog "开机完成: 风扇=$(f_on "$F_FAN" && echo 1 || echo 0) 液冷=$(f_on "$F_PUMP" && echo 1 || echo 0) 分离=$(f_on "$F_CHARGE" && echo 1 || echo 0) 温控=$(f_on "$F_THERMAL" && echo 1 || echo 0) 屏蔽=$(thermal_effective && echo 1 || echo 0) 加速=$(f_on "$F_BOOST" && echo 1 || echo 0) 触控=$(f_on "$F_TOUCH" && echo 1 || echo 0) 采样率=$(f_on "$F_RATE" && echo 1 || echo 0) 亮度=$(f_on "$F_BRIGHT" && echo 1 || echo 0)"

# ---------------- 看门狗 ----------------
# mksh 会等前台子进程结束后才处理 trap；整段 sleep 15 会让 TERM 延迟 15 秒，
# 拆成 1 秒一片，优雅停止最多等 1 秒。
svc_sleep() {
    local n="$1"
    while [ "$n" -gt 0 ]; do
        sleep 1 2>/dev/null
        n=$((n - 1))
    done
}

while :; do
    svc_sleep 15
    if [ -f "$F_TOUCH" ]; then
        if ! touch_verify; then
            mlog "看门狗: 触控参数被改动，重新写入"
            touch_apply
        fi
    fi
    if [ -f "$F_RATE" ]; then
        rate_verify || { mlog "看门狗: 采样率被改动，重新写入"; rate_boost_on; }
    fi
    # 亮度守护是一次性长驻子进程。运行期才打开功能时 BRIGHT_PID 为空，
    # 也必须在这里拉起；否则界面显示已开，但没有任何进程写亮度节点。
    if [ -f "$F_BRIGHT" ] && [ ! -f "$BRIGHT_NA" ]; then
        if [ -z "$BRIGHT_PID" ] || ! kill -0 "$BRIGHT_PID" 2>/dev/null; then
            bright_daemon &
            BRIGHT_PID=$!
            mlog "看门狗: 亮度守护已启动"
        fi
    fi
    if [ -z "$WEBUI_PID" ] || ! kill -0 "$WEBUI_PID" 2>/dev/null; then
        webui_loop &
        WEBUI_PID=$!
        DAEMONS="$SEP_PID $WEBUI_PID"
        mlog "看门狗: WebUI 循环已重启"
        continue
    fi
    _age=$(stat_age)
    if [ "$_age" -gt "$WEBUI_STALE_MAX" ] 2>/dev/null; then
        mlog "看门狗: 快照 ${_age}s 未更新，重启 WebUI 循环"
        kill "$WEBUI_PID" 2>/dev/null; sleep 1 2>/dev/null; kill -9 "$WEBUI_PID" 2>/dev/null
        webui_loop &
        WEBUI_PID=$!
        DAEMONS="$SEP_PID $WEBUI_PID"
    fi
done
