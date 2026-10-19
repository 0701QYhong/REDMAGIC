#!/system/bin/sh
# ============================================================
# 开机最早期（post-fs-data）：只做两件必须在 system_server 之前完成的事
#   1) 日志轮转
#   2) 若开启了温控屏蔽，提前把空配置 bind 上去
# 不 source lib：此时依赖尚未就绪，逻辑全部自包含。
# ============================================================
MODDIR=${0%/*}
LOG_FILE="$MODDIR/REDMAGIC.log"
TARGET=/vendor/etc/thermal-engine.conf

if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ] 2>/dev/null; then
    tail -n 1600 "$LOG_FILE" > "$LOG_FILE.prev" 2>/dev/null
    : > "$LOG_FILE"
fi

want=0
for f in "$MODDIR/state.txt" "$MODDIR/config.txt"; do
    [ -f "$f" ] || continue
    v=$(grep -o '^温控移除=.*' "$f" 2>/dev/null | cut -d= -f2- | tail -n 1)
    case "$v" in 0|1) want=$v;; esac
done

if [ "$want" = "1" ] && [ -e "$TARGET" ]; then
    : > "$MODDIR/conf/empty.conf" 2>/dev/null
    mount --bind "$MODDIR/conf/empty.conf" "$TARGET" 2>/dev/null
fi
exit 0
