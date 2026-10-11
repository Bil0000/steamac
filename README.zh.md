# steamac：运行正版 EAC 游戏，并提供 DXMT 图形路径

[English](README.md) · [Русский](README.ru.md) · **简体中文**

**[steamac](https://github.com/fxgl/steamac) 的分支，面向 Apple Silicon Mac。可运行带有正版 Easy Anti-Cheat 的
x86-64 Windows 游戏（已验证：VRChat），并提供两条图形路径可选。**

- **Vulkan（经典）**：Direct3D 经 DXVK 转为 SteamOS 内的 Vulkan（Venus），再经 KosmicKrisp 或 MoltenVK 在 Mac 上运行。
  这是上游 steamac 的路径。
- **DXMT（精简）**：Direct3D 11 经 [DXMT](https://github.com/3Shain/dxmt) 处理。它的 Metal 调用通过专用的 virtio-gpu
  通道在 Mac 上原生执行，转换层更少。

EAC 客户端是 Proton EasyAntiCheat Runtime 自带的原版。没有任何东西伪造、重放或绕过它的结果。与 FX GAMES、Valve、
Epic Games、VRChat 及 DXMT 作者均无关联。

状态：仅在一台 Mac 和一款带反作弊的游戏上验证过。默认使用 Vulkan 路径；DXMT 需在设置中开启。已公布的 VRChat 帧率
只有 Vulkan 路径的（轻量世界、1280x800 下约 26-30 fps）；DXMT 路径暂无公布数据。

## 要求

| 需要 | 说明 |
|---|---|
| Apple Silicon Mac | 已在 M2 MacBook Air（16 GB、macOS 27.0）上验证；其他 Mac 未测试 |
| macOS 15 或更新 | KosmicKrisp（更快的 Vulkan 驱动）需要 macOS 26。DXMT 路径的主机端库按 macOS 15.5 或更新构建 |
| 可用磁盘空间 | 创建 SteamOS 磁盘期间，其所在卷约需 14 GB（之后约 9 GB），另加游戏所需空间（home 大小在创建时选择，之后可用“扩展磁盘…”扩大） |
| 内存 | 至少 16 GB，更少不受支持。虚拟机内存自动取 Mac 内存的一半（4-16 GiB） |
| Steam 账号 | 游戏在 SteamOS 内安装和运行 |

## 安装与首次启动

1. 从本分支的发布页下载 `FX-Steam-Launcher-<版本>.dmg`，把 **FX Steam Launcher.app** 拖到“应用程序”并打开。
2. 首次启动时选择**新建磁盘…**。应用会下载 Valve 的 SteamOS 映像，校验并完成设置。此过程较久，但只需一次。
3. 在窗口中登录 Steam。保持 **16:10** 的窗口大小（设置 > 显示 > 默认窗口大小；默认的 1280×800 即 16:10）。16:9 的游戏
   在 16:10 窗口中会出现黑边。
4. macOS 询问时允许**麦克风**权限。没有它，客户机的音频采集会反复失败，游戏可能卡顿。
5. 在 Steam 中安装 VRChat，把它的兼容工具设为 **Proton Experimental**，并安装 **Proton EasyAntiCheat Runtime**。完整步骤见
   [SETUP.md](SETUP.md)。

## 选择图形路径

设置 > 高级 > **图形路径**：*DXMT（精简）* 或 *Vulkan（经典）*；下次启动时生效。无需为每个游戏单独设置：Steam 启动时，
每个已安装的 Proton 都会获得所选路径，并由 Proton 放入每个游戏的前缀。切回 *Vulkan* 会原样恢复 Proton 自带的文件。
DXMT 覆盖 Direct3D 11（及 10）；Direct3D 12 游戏请用 *Vulkan*（在 DXMT 下未测试或受限）。在真实前缀上，DXMT 下的 EAC
在首次启动前尚未验证；若 EAC 失败，请切换到 *Vulkan*。

**Metal 性能 HUD** 在两条路径上都能显示帧率：设置 > 显示、“显示”菜单或 Ctrl+Cmd+P。游戏运行时可随时开关。

## Easy Anti-Cheat

EAC 在 SteamOS 内由 Valve 的 FEX 模拟器运行。本分支打过补丁的 FEX 可通过 VRChat 的 EAC 检查。目前 VRChat 需要两个手动
步骤，均计划自动化：

1. 安装打过补丁的 FEX：启用 SSH（设置 > 高级），然后在客户机中运行 `build-fex.sh` 和 `install-fex-tool.sh`
   （[fex-eac/README.md](fex-eac/README.md)）。
2. 设置 VRChat 的 Steam 启动选项（`EAC_LAUNCHERDIR`、`PROTON_EAC_RUNTIME`、`WINE_CPU_TOPOLOGY` 等），完全照
   [fex-eac/README.md](fex-eac/README.md) 与 [SETUP.md](SETUP.md) 所给。

- **预期结果：**EAC 启动器输出 `Launcher finished with: 301, 'Easy Anti-Cheat successfully loaded in-game'`，游戏日志出现
  `AntiCheat Session Begin: Success`。
- **预期无法工作：**拒绝虚拟机的反作弊，以及在 EAC 的 Linux 模块之外还带有自身反调试检查的游戏。
- **Steam 更新之后：**若 Steam 更新其 FEX 工具，会覆盖打过补丁的版本。请再次运行 `sh install-fex-tool.sh`。

## 故障排除

| 现象 | 处理 |
|---|---|
| DXMT 下游戏窗口一直是黑的 | 确认设置中选的是 *DXMT*，更改路径后重启启动器；回退到 *Vulkan* |
| DXMT 下 EAC 失败 | 切换到 *Vulkan* 并重启启动器 |
| EAC 无法完成，或在 Steam 更新后失败 | 打过补丁的 FEX 缺失或被 Valve 的版本覆盖；运行 `sh install-fex-tool.sh status` |
| 进入世界前停顿约一分钟 | 检查启动选项中是否有 `WINE_CPU_TOPOLOGY` |
| 卡顿并伴有爆音 | 授予麦克风权限（系统设置 > 隐私与安全性 > 麦克风） |
| 首次启动很慢 | 着色器对每个游戏和每条路径只编译一次；之后的启动会更快 |

更多：[docs/eac-troubleshooting.md](docs/eac-troubleshooting.md)。

## 限制

- 仅验证了一台机器（M2、16 GB、macOS 27.0）和一款 EAC 游戏（VRChat）。
- DXMT：仅支持 Direct3D 11/10。功能级别上限为 11_1（无 DXIL，无保守光栅化）。
- 经 D3DMetal 支持 Direct3D 12 仅在**计划**中，未包含。
- DXMT 设置对所有游戏生效；此时游戏的 Metal 层覆盖整个虚拟机视图（窗口化游戏或 alt-tab 会显示游戏层）。
- 内存需求超过虚拟机所得（设置 > 高级）的游戏会使用交换。
- 构建中包含异步管线编译，但默认关闭且不推荐（实测更差）。
- 麦克风测试很少；麦克风启动后卡死的可能性尚未完全排除。重新构建或重新签名的应用会再次请求麦克风权限。

## 文档

| 页面 | 内容 |
|---|---|
| [SETUP.md](SETUP.md) | 完整的设置指南：安装、图形路径、Easy Anti-Cheat、故障排除（英文） |
| [docs/fork.md](docs/fork.md) | 本分支的改动及其状态（英文） |
| [docs/eac-how-it-works.md](docs/eac-how-it-works.md) | EAC 链路，以及为何要替换 FEX（英文） |
| [docs/eac-performance.md](docs/eac-performance.md) | 测量与限制（英文） |
| [fex-eac/README.md](fex-eac/README.md) | 打过补丁的 FEX 的安装与启动选项 |
| [docs/upstream/README.zh.md](docs/upstream/README.zh.md) | 上游 steamac 的文档（Apache-2.0，© FX GAMES FZ LLC） |

## 许可与归属

| 组件 | 许可 |
|---|---|
| steamac（本分支） | Apache-2.0，© FX GAMES FZ LLC 及贡献者（`LICENSE`、`NOTICE`） |
| FEX-Emu 补丁（`fex-eac/patches/`） | MIT，与 FEX-Emu 相同 |
| DXMT 及本分支的补丁（`host/dxmt/patches/`） | LGPL-2.1 |
| wmtr（DXMT 远程调用层，`wmtr/`） | BSD-3-Clause |
| libkrun 及其补丁 | Apache-2.0 |
| virglrenderer、Mesa / KosmicKrisp | MIT |
| MoltenVK | Apache-2.0 |
| DXVK（zlib）、Proton / Wine（LGPL-2.1 等） | 遵循各上游；由 Steam 安装，不随应用分发 |
| Linux 内核衍生物 | GPL-2.0-only；每个发布版的完整源码随该版本提供 |

**不包含 D3DMetal。**应用不含游戏文件和 EAC 二进制文件。EAC 来自 Valve 的 Proton EasyAntiCheat Runtime，由 Steam 安装。
