# hidpi — 开源的 macOS 分辨率工具

[![build](https://github.com/wloveqbest/HiDPI/actions/workflows/build.yml/badge.svg)](https://github.com/wloveqbest/HiDPI/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/wloveqbest/HiDPI)](https://github.com/wloveqbest/HiDPI/releases)

菜单栏里直接切换**真实显示器**的分辨率与颜色描述文件；需要系统没给的尺寸时，注入一条 override，再软件断开/重连显示器让它生效 —— 全程不拔线、不重启、不需要付费授权。

> v1.0.0 · 仅 Apple Silicon（macOS 12+）· MIT

> 独立实现，不包含、不修改、不绕过任何商业软件的代码或授权校验。私有 API 声明参考 BetterDummy 早期开源版（MIT）——详见 [许可与署名](#许可与署名)。

## 能做什么

| 能力 | 需要 root | 状态 |
|---|---|---|
| 列出真屏分辨率并即时切换 | 否 | ✅ |
| 刷新率切换（含 24/30Hz 影院档） | 否 | ✅ |
| HiDPI 开关；标注「原生」与「无 HiDPI」 | 否 | ✅ |
| 注入自定义分辨率（如 2400×1350 HiDPI） | 是 | ✅ 脚本 |
| ColorSync 颜色描述文件切换 | 否 | ✅ |
| 合盖状态显示、保持屏幕常亮 | 否 | ✅ |
| 开机自启动 | 否 | ✅ |
| 虚拟屏 / 亮度 / HDMI 范围 / HDR | — | ❌ 不做，理由见下 |

## 安装

从 [Releases](https://github.com/wloveqbest/HiDPI/releases) 下载最新的 `HiDPI-x.y.z.dmg`，打开后把 `HiDPI.app` 拖进 Applications。

首次打开会被 Gatekeeper 拦一次（ad-hoc 签名、未公证）：

```bash
xattr -dr com.apple.quarantine /Applications/HiDPI.app
```

或右键点 App → 打开。

**自己构建**（需要 Command Line Tools，不需要完整 Xcode）：

```bash
swift build -c release
./scripts/build-app.sh          # 产出 dist/HiDPI.app 与 dist/HiDPI-x.y.z.dmg
```

## 菜单设计

单显示器时**扁平展示**；多显示器才收进「显示器 ▸」。菜单项带 SF Symbols 图标，状态行用次要色小字。

```
H27T22C · 1920×1080 HiDPI · 75Hz · 开盖     ← 状态行（只读）
──────────────
▣ 分辨率 ▸        常见尺寸，当前项打勾；缺 HiDPI 的直接标注
⟳ 刷新率 ▸        当前分辨率下的全部刷新率
✦ 启用 HiDPI
🎨 颜色描述文件 ▸   系统默认 / 各 ICC
──────────────
☀ 保持屏幕常亮
⏻ 开机自启动
──────────────
退出 HiDPI
```

呈现层（`MenuBuilder`）与状态层（`AppDelegate`）分离：前者只决定长什么样，动作通过 `MenuActionRouter` 的闭包回传。

收纳原则：

| 位置 | 内容 | 理由 |
|---|---|---|
| 直接展示 | 分辨率、刷新率、HiDPI、颜色描述文件 | 高频，最多两次点击 |
| 直接展示 | 保持常亮、开机自启动 | 一次性开关 |
| 收进子菜单 | 全部分辨率档位（150+ 个） | 只露常见尺寸 |
| 收进子菜单 | 多显示器各自的设置 | 单屏时不出现这层 |
| 状态行 | 显示器名、模式、刷新率、合盖状态 | 只读 |

## 针对"仅外接屏"的优化

| 优化 | 做法 |
|---|---|
| 菜单扁平 | 单屏时不出现「显示器 ▸」层级 |
| 合盖状态可见 | 状态行读 `AppleClamshellState` 显示「开盖 / 已合盖」 |
| 唤醒后重放 ICC | 监听 `didWake`，延迟重放；不与用户操作互相覆盖 |
| 保持屏幕常亮 | `IOPMAssertion`（默认关） |
| 原生分辨率判定 | 取最大 **LoDPI** 模式，避免把 5120×2880 超采样当面板原生 |
| 自定义分辨率 | hex 路径 override + 软件断开重连激活 |
| 登录后自启 | LaunchAgent `LimitLoadToSessionType = Aqua` |

## 颜色描述文件

走 ColorSync：

- 列出 `/System/Library/ColorSync/Profiles`、`/Library/ColorSync/Profiles`、`~/Library/ColorSync/Profiles`
- **只接受「显示器类 + RGB」**（ICC 头 12–15 = `mntr`、16–19 = `RGB `）。抽象类（`abst`，如 Sepia Tone）、色彩空间类（`spac`）和灰度 profile 强设时会让 ColorSync 内部断言直接 abort（SIGABRT），`@try/@catch` 拦不住，只能在入口过滤 + 应用前二次校验
- 应用时调用 `ColorSyncDeviceSetCustomProfiles`；「系统默认」传 `NULL` 清除自定义项
- 不需要 root

## 机制

1. **切换**：`CGSConfigureDisplayMode`（SkyLight 私有，`dlopen`+`dlsym`）
2. **注入**：`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>` 写 `scale-resolutions`
   - 注意新版 macOS 只认**十六进制**路径，网上教程的十进制写法无效
3. **激活**：`CGSConfigureDisplayEnabled` 断开显示器再重连，迫使 WindowServer 重读 override
   - `SLSDetectDisplays` 和显示休眠/唤醒都**不够**（`fs_usage` 实测：这两种方式下 Overrides 目录零访问）
4. **权限**：写 `/Library` 需要 root，App 保持无特权，由脚本 `sudo` 完成

## 注入自定义分辨率（可选）

> 只用常见分辨率的话不需要这一节。注入是为了拿到系统没给的尺寸，或给只有 LoDPI 的尺寸补 HiDPI 变体。

```bash
swift build -c release

# 看要写什么（不需要 root）
./scripts/add-custom-resolution.sh 2 2400x1350 --dry-run

# 真正写入 + 自动激活（提示密码，黑屏约 2 秒）
./scripts/add-custom-resolution.sh 2 2400x1350

# 一次注入 9 档常用 16:9
./scripts/add-custom-resolution.sh 2 --presets

# 回滚（同时撤销全局开关）
./scripts/add-custom-resolution.sh 2 --remove
```

脚本特性：hex + decimal 双路径、合并已有条目、写完自动激活、**前后对比模式表**并报告新增档位。

上限：HiDPI 背衬宽度约 **5120 像素**，`2880×1620`、`3008×1692` 之类会被系统丢弃。

## 命令行

| 命令 | 作用 |
|---|---|
| `hidpi list` | 列出在线显示器及逻辑/像素尺寸 |
| `hidpi modes <id>` | 列出全部模式，标注 HiDPI/LoDPI 与当前项 |
| `hidpi set <id> <索引>` | 立即切换模式 |
| `hidpi cycle <id> [秒]` | 软件断开/重连（激活 override） |
| `hidpi info <id>` | 厂商号/型号号与 override 路径 |
| `hidpi state` | 合盖状态 |
| `hidpi profiles` | 列出可用的颜色描述文件 |
| `hidpi profile <id> [路径\|default]` | 查看/应用颜色描述文件 |
| `hidpi version` / `help` | 版本与帮助 |

## 架构

```
Sources/
  HDShim/         薄 C 层（ObjC），按关注点拆分
                  ├ hd.h / hd_internal.h   公开接口 / 内部符号解析
                  ├ hd_modes.m             模式枚举、切换、断开重连
                  ├ hd_system.m            合盖状态、防睡眠、EDID 身份
                  └ hd_color.m             ColorSync ICC 应用/查询
  HiDPICore/      共享 Swift 模型
                  ├ DisplayCatalog         模式表、去重、常见尺寸、原生判定
                  └ ColorProfile           枚举、命名、当前值、应用
  hidpi/          CLI
                  ├ main.swift             参数解析与分发
                  └ Commands.swift         子命令实现
  HiDPIMenuBar/   菜单栏 App
                  ├ main.swift             入口 + 单实例保护
                  ├ AppDelegate.swift      状态、生命周期、副作用
                  ├ MenuBuilder.swift      菜单呈现层
                  ├ LaunchAtLogin.swift    LaunchAgent 封装
                  └ DisplayList.swift      NSScreen → 显示器清单
```

设计约束：

- **私有符号一律运行时解析**（`dlopen`/`dlsym`），符号缺失只返回错误码，不会让进程起不来
- **核心逻辑与 UI 分离**：模式表处理都在 `HiDPICore`
- **写系统状态的能力集中在脚本**：`/Library` 写入走 `sudo`，App 保持无特权

## 已知限制

- 仅 **Apple Silicon**（arm64）；macOS 12+
- **ad-hoc 签名、未公证**：其他机器首次打开需右键 → 打开，或 `xattr -dr`
- 私有 API 不受 Apple 支持，系统升级可能失效
- 不能跑在 Rosetta 下
- 背衬宽度超过约 5120 像素的档位会被丢弃
- 内建屏无法靠断开重连激活，仍需重启
- override 按 vendor/model 生效，影响所有同型号显示器
- **HDMI 范围（Full / Limited）无系统接口**：SkyLight / CoreGraphics 里没有对应符号，BetterDisplay 也没有；只能在显示器 OSD 调整

## 许可与署名

MIT —— 见 [LICENSE](LICENSE)。

私有类型的 `@interface` 声明参考自 **BetterDummy OpenSource Edition**（MIT，Copyright (c) 2021 Istvan T.），即 [waydabber/BetterDisplay 的 `opensource` 分支](https://github.com/waydabber/BetterDisplay/tree/opensource)。上游当前 5.x 已闭源，与本项目无代码关系。
