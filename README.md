# REDMAGIC 内核模块（NX809J）

KernelSU / ReSukiSU 模块，用 Shell 守护进程控制红魔 Pro+ 系列的风扇、液冷、充电、温控、触控、采样率和亮度，WebUI 通过 `window.ksu.exec` 读写模块目录内的命令队列与状态快照。

## 仅限红魔 Pro+ 系列

> **非红魔 Pro+ 系列设备禁止刷入。**
>
> 本模块按红魔 Pro+ 系列的节点布局编写，目前只在 **NX809J（红魔 11 Pro+）** 上做过实机验证。
> 其它机型（包括非 Pro+ 系列）的温控、充电、触控节点并不通用，刷入后可能功能失效，甚至无法正常开机。
> 安装前请先核对 `nodes.req` 里的节点路径，任何一项不存在都应立即停止。

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

## 许可

本项目采用 [PolyForm Noncommercial License 1.0.0](LICENSE)：源码公开，可自由用于个人学习、研究、修改和分享，**禁止任何商业用途**。分发时请保留署名和本许可证。

欢迎 Issue / PR 交流，但请勿将本项目或其修改版用于售卖、付费服务或其他商业行为。
