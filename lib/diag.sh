#!/system/bin/sh
# ============================================================
# 自检：前端「导出日志」按钮会跑它，也给人直接看。
# 只读；退出码 0 = 无失败项。
# ============================================================
MODDIR=${MODDIR:-/data/adb/modules/REDMAGIC}
if [ -z "$(command -v cfg_set)" ]; then
    . "$MODDIR/paths.sh"
    . "$MODDIR/common.sh"
    for _f in system thermal fanpump charge touch bright state status; do
        [ -f "$MODDIR/lib/$_f.sh" ] && . "$MODDIR/lib/$_f.sh"
    done
fi
L=${L:-/sdcard/Download/REDMAGIC_debug.log}
N_OK=0; N_FAIL=0; N_WARN=0

sec() { printf '\n== %s ==\n' "$1" >> "$L"; }
ok()  { N_OK=$((N_OK+1));     printf '[ OK ] %s\n' "$1" >> "$L"; }
no()  { N_FAIL=$((N_FAIL+1)); printf '[FAIL] %s\n' "$1" >> "$L"; }
wa()  { N_WARN=$((N_WARN+1)); printf '[WARN] %s\n' "$1" >> "$L"; }
kv()  { printf '       %s = %s\n' "$1" "$2" >> "$L"; }
nd()  { if [ -e "$1" ]; then printf '%s' "$(cat "$1" 2>/dev/null)"; else printf 'N/A'; fi; }

diag_main() {
    local v pid age up
    : > "$L" 2>/dev/null || { L=/data/local/tmp/REDMAGIC_debug.log; : > "$L" 2>/dev/null; }

    sec "基本信息"
    v=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
    kv "模块版本" "${v:-unknown}"
    kv "时间" "$(date 2>/dev/null)"
    read -r up _ < /proc/uptime 2>/dev/null
    kv "开机时长(秒)" "${up%%.*}"
    kv "内核" "$(uname -r 2>/dev/null)"

    sec "服务"
    pid=$(cat "$SVC_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then ok "服务在跑 (pid=$pid)"; else no "服务未运行"; fi
    age=$(stat_age)
    if [ "$age" -le 30 ] 2>/dev/null; then ok "快照新鲜 (${age}s)"; else no "快照过期 (${age}s)"; fi

    sec "风扇"
    kv "系统开关" "$(nd "$FAN_ENABLE")"
    kv "档位" "$(nd "$FAN_LEVEL")"
    kv "模块接管" "$(f_on "$F_FAN" && echo 1 || echo 0)"
    kv "记忆档位" "$(stq '风扇档位')"
    if [ -f "$F_FAN" ]; then
        if [ "$(nd "$FAN_ENABLE")" = "1" ]; then ok "风扇由模块控制"; else wa "模块已开但系统关着风扇"; fi
    else
        wa "风扇未接管"
    fi

    sec "液冷"
    kv "系统开关" "$(nd "$PUMP_ENABLE")"
    kv "转速" "$(nd "$PUMP_SPEED")"
    kv "模块接管" "$(f_on "$F_PUMP" && echo 1 || echo 0)"
    kv "记忆档位" "$(stq '液冷档位')"

    sec "充电"
    kv "电量" "$(battery_capacity)%"
    kv "温度" "$(battery_temp_deg)℃"
    kv "分离阈值" "$(sep_limit)%"
    kv "系统分离开关" "$(sep_now)"
    kv "restrict_cur" "$(nd "$CHG_DIR/restrict_cur")"

    sec "温控屏蔽"
    kv "模块开关" "$(f_on "$F_THERMAL" && echo 1 || echo 0)"
    if thermal_effective; then ok "温控配置已被空文件顶替";
    elif [ -f "$F_THERMAL" ]; then no "模块已开但屏蔽未生效";
    else wa "未开启"; fi

    sec "充电加速"
    kv "模块开关" "$(f_on "$F_BOOST" && echo 1 || echo 0)"
    kv "温度上限" "$(boost_limit)℃"
    if [ -f "$F_BOOST" ]; then boost_guard && ok "加速生效中" || wa "加速条件未满足（正常保护行为）"; fi

    sec "触控"
    kv "缺失节点数" "$(touch_missing_nodes)"
    kv "预设" "$(stq '触控预设')"
    if [ "$(touch_missing_nodes)" = "0" ]; then ok "触控节点齐全"; else no "触控节点缺失"; fi
    if [ -f "$F_TOUCH" ] && touch_verify; then ok "13 项与记忆一致"; else wa "触控参数未对齐"; fi

    sec "采样率"
    kv "当前" "$(rate_current)Hz"
    kv "目标" "$(rate_target)Hz"

    sec "亮度"
    kv "模块开关" "$(f_on "$F_BRIGHT" && echo 1 || echo 0)"
    kv "亮度" "$(nd "$BL_BRIGHT")/$(nd "$BL_MAX")"

    sec "基线"
    kv "风扇档位快照" "$([ -f "$SNAP_FAN" ] && echo 有 || echo 无)"
    kv "液冷快照" "$([ -f "$SNAP_PUMP" ] && echo 有 || echo 无)"
    kv "加速快照" "$([ -f "$SNAP_BOOST" ] && echo 有 || echo 无)"
    kv "频率权限快照" "$([ -f "$SNAP_CFREQ" ] && echo 有 || echo 无)"
    kv "解除热降流" "$(f_on "$F_BOOST_HEAT" && echo 1 || echo 0)"

    sec "近期日志"
    tail -n 20 "$LOG_FILE" >> "$L" 2>/dev/null

    sec "结论"
    kv "通过" "$N_OK"
    kv "警告" "$N_WARN"
    kv "失败" "$N_FAIL"
    if [ "$N_FAIL" -eq 0 ]; then
        printf '\n无失败项\n' >> "$L"
    else
        printf '\n有 %s 项失败\n' "$N_FAIL" >> "$L"
    fi
    [ "$N_FAIL" -eq 0 ]
}

diag_main
exit $?
