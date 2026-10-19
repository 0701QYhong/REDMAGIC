# REDMAGIC 内核模块（NX809J）

KernelSU / ReSukiSU 模块，用 Shell 守护进程控制 NX809J 的风扇、液冷、充电、温控、触控、采样率和亮度，WebUI 通过 `window.ksu.exec` 读写模块目录内的命令队列与状态快照。

## 安装

1. 打包：`powershell -File tools/build.ps1`，产物在 `dist/`。
2. 在 KernelSU / ReSukiSU 里安装 ZIP（安装器会执行 `customize.sh`，节点校验失败会中止）。
3. 重启后打开模块 WebUI。

所有功能默认关闭；开关状态记在模块目录的 `state.txt`，卸载时 `uninstall.sh` 会还原改过的节点。

## 目录

- `service.sh`：常驻服务，命令分发、状态对账、看门狗
- `lib/`：各功能实现（`touch.sh` 触控、`charge.sh` 充电、`thermal.sh` 温控等）
- `webroot/`：静态 WebUI
- `tools/check.ps1`：语法/LF/重复函数检查

## 说明

- 仅适配 NX809J（节点清单见 `nodes.req`）。
- 触控快照在首次接管时写入 `touch_snapshot.txt`，关闭或卸载时按原值还原。
- 采样率接管前的系统值记在 `.rate_orig`，关闭时还原，不会直接删除系统设置。
