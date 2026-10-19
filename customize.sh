#!/system/bin/sh
# ============================================================
# KernelSU / Magisk 模块安装入口。
# 唯一安装入口。校验脚本特意不叫 install.sh：KernelSU 会把 install.sh
# 当旧式安装器直接跑，而那个阶段 MODPATH 里还没有 nodes.req/lib。
# ============================================================
MODDIR="${MODPATH:-$PWD}"
export MODDIR

if ! sh "$MODDIR/validate_nodes.sh"; then
    echo "! 机型节点校验失败，安装中止"
    exit 1
fi

# 模块脚本统一可执行，省得安装器按 umask 解包后权限不一致
for _f in "$MODDIR"/*.sh "$MODDIR"/lib/*.sh; do
    [ -f "$_f" ] && chmod 755 "$_f" 2>/dev/null
done
exit 0
