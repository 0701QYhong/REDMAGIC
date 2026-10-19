#!/system/bin/sh
# ============================================================
# 温控屏蔽：用一个空文件顶替 /vendor/etc/thermal-engine.conf，并把 cpufreq 节点解权。
# 所有操作幂等；失败一律留 .last_error，呼叫方据此回退记忆值。
# 判定口径只有一个 thermal_effective()：挂上了 且 目标为空。
# ============================================================

CFREQ_MODE=664
# GPU 频率：Adreno 走 kgsl 的 devfreq 子目录，但 NX809J(Android 16) 上没有
# devfreq/，只有 max_gpuclk/min_gpuclk 这两组。两条路径都列，存在哪个用哪个。
cfreq_nodes() {
    printf '%s\n' \
        /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq \
        /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq \
        /sys/class/kgsl/kgsl-3d0/devfreq/max_freq \
        /sys/class/kgsl/kgsl-3d0/devfreq/min_freq \
        /sys/class/kgsl/kgsl-3d0/max_gpuclk \
        /sys/class/kgsl/kgsl-3d0/min_gpuclk
}

# 结果缓存 1 秒：reconcile（3s）和 status（0.5s）都会问一次，mount 每次都要 fork 解析
TE_AT=""
TE_VAL=""
thermal_effective() {
    local t
    t=$(date +%s 2>/dev/null)
    if [ "$TE_AT" = "$t" ] && [ -n "$TE_VAL" ]; then
        [ "$TE_VAL" = "1" ]
        return $?
    fi
    TE_AT="$t"
    if thermal_bound && [ ! -s "$THERMAL_TARGET" ]; then TE_VAL=1; else TE_VAL=0; fi
    [ "$TE_VAL" = "1" ]
}

# 精确匹配 "on <target> type"：只比路径会出现 a/b 命中 a/b/c 的误判
thermal_bound() {
    local dev mnt rest
    while read -r dev mnt rest; do
        [ "$mnt" = "$THERMAL_TARGET" ] && [ -n "$rest" ] && return 0
    done < /proc/self/mounts 2>/dev/null
    return 1
}

# 解 bind。只解这一层的 bind，不能调 thermal_off（它还会还原频率权限）。
thermal_umbind() {
    local i=0
    while thermal_bound && [ "$i" -lt 8 ]; do
        umount "$THERMAL_TARGET" 2>/dev/null || umount -l "$THERMAL_TARGET" 2>/dev/null
        i=$((i + 1))
    done
    thermal_bound && return 1
    return 0
}

cfreq_unlock() {
    local n=0 m f seen=""
    : > "$SNAP_CFREQ" 2>/dev/null
    for f in $(cfreq_nodes); do
        [ -e "$f" ] || continue
        # 各核 scaling_max_freq 权限共享，重复路径只算一次，日志里的计数才准
        case " $seen " in *" $f "*) continue;; esac
        seen="$seen $f"
        m=$(stat -c %a "$f" 2>/dev/null)
        case "$m" in ''|*[!0-7]*) continue;; esac
        printf '%s=%s\n' "$f" "$m" >> "$SNAP_CFREQ" 2>/dev/null
        # stat -c %a 是八进制字符串，直接做数值比较会把它当十进制（664 > 1000 是错的）。
        # 补到固定 8 位按字符串比，等价于按八进制从左到右比，且不依赖 shell 的进制前缀：
        # 8 位留出 2 位特殊位，1000/1001 这类"看起来数字很大、实际权限很严"的也会放宽。
        _mo=$(printf '%08d' "$m")
        _mn=$(printf '%08d' "$CFREQ_MODE")
        # 已达标（_mo >= _mn）就跳过：排序后第一行是 _mn 说明 _mn 不小于 _mo
        if [ "$(printf '%s\n%s\n' "$_mo" "$_mn" | sort | head -n 1)" = "$_mn" ]; then
            continue
        fi
        chmod "$CFREQ_MODE" "$f" 2>/dev/null && n=$((n + 1))
    done
    [ "$n" -gt 0 ] && mlog "频率解权: $n 个节点放宽到 $CFREQ_MODE"
    return 0
}

# 还原权限：scaling_max_freq 的权限在 CPU 之间共享，chmod 一个会重置全部，
# 所以按权限值从宽到严分两轮落，最严格的最后写，不会被后续行冲掉。
cfreq_restore() {
    local line f m
    [ -f "$SNAP_CFREQ" ] || return 0
    for want in 664 444; do
        while IFS= read -r line; do
            f=${line%%=*}
            m=${line##*=}
            [ "$f" = "" ] && continue
            [ "$m" = "$want" ] || continue
            chmod "$m" "$f" 2>/dev/null
        done < "$SNAP_CFREQ"
    done
    # 其余权限值原样还原
    while IFS= read -r line; do
        f=${line%%=*}
        m=${line##*=}
        case "$m" in ''|*[!0-7]*) continue;; esac
        case "$m" in 664|444) continue;; esac
        chmod "$m" "$f" 2>/dev/null
    done < "$SNAP_CFREQ"
    rm -f "$SNAP_CFREQ" 2>/dev/null
    return 0
}

# 空文件顶替：thermal HAL 读不到任何阈值表，等于所有策略都不触发。
# 相比「bind 一份把阈值改成 999000 的表」，空文件更彻底——未列入的段也一并消失。
thermal_lockstate() {
    [ -e "$THERMAL_TARGET" ] || { errlog "温控屏蔽: 本机无 $THERMAL_TARGET"; return 1; }
    : > "$MODDIR/conf/empty.conf" 2>/dev/null
    [ -f "$MODDIR/conf/empty.conf" ] || { errlog "温控屏蔽: 无法创建空配置文件"; return 1; }
    thermal_umbind
    if ! mount --bind "$MODDIR/conf/empty.conf" "$THERMAL_TARGET" 2>/dev/null; then
        errlog "温控屏蔽: bind 空配置失败"
        return 1
    fi
    cfreq_unlock
    mlog "温控屏蔽: 已生效（空配置顶替 + 频率解权）"
    return 0
}

thermal_on() {
    thermal_lockstate || return 1
    if ! thermal_effective; then
        errlog "温控屏蔽: bind 后目标文件仍非空"
        thermal_umbind
        return 1
    fi
    return 0
}

thermal_off() {
    if thermal_umbind; then
        mlog "温控屏蔽: 已解除"
    else
        errlog "温控屏蔽: 解除 bind 失败（可能被多次叠加）"
    fi
    cfreq_restore
    return 0
}
