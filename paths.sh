#!/system/bin/sh
# ============================================================
# 全部路径常量的唯一来源。改动节点位置只需改这里。
# 被 service.sh / uninstall.sh / lib/*.sh 共同 source。
# ============================================================

MODDIR=${MODDIR:-/data/adb/modules/REDMAGIC}
NL='
'
TAB='	'

# ---------------- WebUI 数据契约 ----------------
# 命令队列：每行一个 {"action":"...","value":"..."}，由 webui 前端追加、loop.sh 消费
WEBUI_CMD="$MODDIR/webui_cmd"
# 状态快照：一份扁平 JSON，前端每 500ms 读一次
WEBUI_STATUS="$MODDIR/webui_status"
# 前端心跳：ksu 一打开 WebUI 就会 touch，进程退出后自然变旧
WEBUI_HB="$MODDIR/.webui_hb"
# 「本进程确实产出过快照」的门控标记：没有它就不判心跳，避免开机首轮误报
WEBUI_HB_SEEN="$MODDIR/.hb_seen"

# ---------------- 用户记忆 ----------------
STATE_FILE="$MODDIR/state.txt"
CONFIG_FILE="$MODDIR/config.txt"

# ---------------- 功能开关（标记文件存在 = 开）----------------
F_FAN="$MODDIR/auto_fan"
F_PUMP="$MODDIR/auto_pump"
F_CHARGE="$MODDIR/auto_charge"
# 温控屏蔽自己的标记：以前错用 auto_charge，把「充电分离」和「温控屏蔽」绑死在同一面旗上
F_THERMAL="$MODDIR/auto_thermal"
F_TOUCH="$MODDIR/auto_touch"
F_BOOST="$MODDIR/auto_chargeboost"
F_BRIGHT="$MODDIR/auto_brightness"
F_RATE="$MODDIR/auto_rate"
# 子选项
F_BOOST_HEAT="$MODDIR/auto_chargeboost_heat"
F_FAN_KEEP="$MODDIR/auto_fan_screen_off"
F_PUMP_KEEP="$MODDIR/auto_pump_screen_off"
F_FAN_TEMP="$MODDIR/auto_fan_temp"
F_PUMP_TEMP="$MODDIR/auto_pump_temp"

# ---------------- 用户数值 ----------------
# 充电分离阈值（%）：达到即把系统充电分离开关置 1
SEP_LIMIT="$MODDIR/sep_limit"
# 充电加速温度上限（℃）：到此温度就恢复限流
BOOST_LIMIT="$MODDIR/boost_limit"
# 触控自定义快照（manual|k=v;k=v;...）：目前只由 teardown 在卸载时清理
TOUCH_SNAPSHOT="$MODDIR/touch_snapshot.txt"
# 触控可用性：读不出原始值（快照缺项）的项按行列出；回滚明细 name=value 按行列出
TOUCH_NA="$MODDIR/touch_na.txt"
TOUCH_RB="$MODDIR/touch_rollback.txt"

# ---------------- 接管快照（存在 = 接管中，内含原值原权限）----------------
SNAP_FAN="$MODDIR/.snap_fan"
SNAP_PUMP="$MODDIR/.snap_pump"
SNAP_BOOST="$MODDIR/.snap_boost"
SNAP_CFREQ="$MODDIR/.snap_cfreq"
SNAP_HEAT="$MODDIR/.snap_heat"
# 息屏保持接管 enable 时的原值原权限
SNAP_FAN_KEEP="$MODDIR/.snap_fan_keep"
SNAP_PUMP_KEEP="$MODDIR/.snap_pump_keep"
# 采样率接管前的系统原值（文本原样保存，包括 "null"）
RATE_SNAPSHOT="$MODDIR/.rate_orig"
# 运行期缓存：避免状态快照每次都 fork settings
SEP_CACHE="$MODDIR/.sep_state"
RATE_CACHE="$MODDIR/.rate_cur"

# ---------------- 运行期 ----------------
LOG_FILE="$MODDIR/REDMAGIC.log"
LOG_PREV="$LOG_FILE.prev"
ERRLOG="$MODDIR/.last_error"
SVC_PID_FILE="$MODDIR/.svc_pid"
SVC_LOCK_FILE="$MODDIR/.svc_lock"
BRIGHT_NA="$MODDIR/.bright_na"

# 判活/清理匹配串：各模块入口同名且 PID 会复用，必须匹配模块绝对路径
SVC_DIR="$MODDIR"
case "$SVC_DIR" in
    /*) ;;
    *) SVC_DIR=$( (cd "$MODDIR" 2>/dev/null && pwd) ) ;;
esac
[ -n "$SVC_DIR" ] || SVC_DIR=/data/adb/modules/REDMAGIC
SVC_CMDLINE_PAT="$SVC_DIR/service\.sh"

# ---------------- 内核节点（validate_nodes.sh 逐项强校验）----------------
# 下面这些都能被环境变量覆盖，只为离线自测：测试时把根指到假目录，
# 不会碰真机节点。真机上环境里没有这些变量，取值就是右边的默认值。
# 风扇
FAN_ENABLE=${FAN_ENABLE:-/sys/kernel/fan/fan_enable}
FAN_LEVEL=${FAN_LEVEL:-/sys/kernel/fan/fan_speed_level}
[ -e "$FAN_LEVEL" ] || FAN_LEVEL=/sys/kernel/fan_speed_level
# 液冷
PUMP_DIR=${PUMP_DIR:-/proc/driver/micropump}
PUMP_ENABLE="$PUMP_DIR/enable"
PUMP_FREQ="$PUMP_DIR/freq"
PUMP_SPEED="$PUMP_DIR/speed"
# 触控（procfs 虚拟节点，只在触控驱动就绪后出现）
TP_DIR=${TP_DIR:-/proc/touchscreen}
TOUCH_TABLE="$MODDIR/lib/touch_table.txt"
# 充电
CHG_DIR=${CHG_DIR:-/sys/class/qcom-battery}
BAT_DIR=${BAT_DIR:-/sys/class/power_supply/battery}
# 充电器在线：Android 13+ 的 UCSI/PD 架构没有 ac 节点，逐级回退
# （NX809J / Android 16 实测：无 ac，只有 usb/policy/ucsi-source-psy-*）
# 注意：绝不能用 $BAT_DIR/../xxx 这种写法。BAT_DIR 是符号链接，
# shell 的 .. 会沿链接目标解析，落到 .../power_supply/battery-charger/power_supply/ 下，
# 那里没有 ac/policy/ucsi —— 实测三个候选全部 miss，最后只是被兜底救回来。
# 用绝对路径 /sys/class/power_supply/ 才是 class 目录本身。
AC_ONLINE=${AC_ONLINE:-}
if [ -z "$AC_ONLINE" ]; then
    for _c in /sys/class/power_supply/ac/online \
              /sys/class/power_supply/ucsi-source-psy-*/online \
              /sys/class/power_supply/policy/online \
              /sys/class/power_supply/usb/online; do
        for _p in $_c; do
            [ -e "$_p" ] && { AC_ONLINE="$_p"; break 2; }
        done
    done
    [ -n "$AC_ONLINE" ] || AC_ONLINE=/sys/class/power_supply/usb/online
    unset _c _p
fi
# 温控（锁定时用 conf/empty.conf 顶替）
THERMAL_TARGET=${THERMAL_TARGET:-/vendor/etc/thermal-engine.conf}
# 亮度
BL_DIR=${BL_DIR:-/sys/class/backlight}
# 降温设备（解除热降流：把 type=battery 的 cooling_device cur_state 钉 0）
CDEV_DIR=${CDEV_DIR:-/sys/class/thermal}

# ---------------- 亮度节点（面板名各机型不同）----------------
BL_BRIGHT="$BL_DIR/panel0-backlight/brightness"
BL_MAX="$BL_DIR/panel0-backlight/max_brightness"
