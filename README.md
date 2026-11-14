# hidpi — 开源的 macOS HiDPI 工具

用 macOS 私有 `CGVirtualDisplay` API 在内存里造一块 **2x 背衬的虚拟显示器**，从而在任意 Mac 上获得 HiDPI 分辨率选项。这是 BetterDisplay / BetterDummy 最核心的那部分能力，本项目用约 900 行 Swift + ObjC 独立实现，MIT 许可，**不需要任何付费授权**。

> 本项目是**独立实现**，不包含、不修改、不绕过任何商业软件的代码或授权校验。机制参考了 BetterDummy 早期开源版（MIT）——详见 [许可与署名](#许可与署名)。

## 两种形态

| 形态 | 路径 | 适合 |
|---|---|---|
| **菜单栏 App** | `dist/HiDPI.app`（DMG 同目录） | 日常用：双击即用，点菜单栏图标选分辨率 |
| 命令行工具 | `hidpi`（同 DMG 内 `hidpi-cli`） | 脚本、launchd 常驻、调试 |

## 安装

```bash
# 方式一：直接装 DMG 里的 App
open dist/HiDPI-0.1.0.dmg      # 把 HiDPI 拖进 Applications 即可

# 方式二：自己构建
./scripts/build-app.sh          # 产出 dist/HiDPI.app 与 dist/HiDPI-0.1.0.dmg
```

App 只出现在菜单栏（`LSUIElement`，不占 Dock），已做**单实例保护**：重复启动只会激活已有实例，不会叠出多块虚拟屏。

## 菜单栏 App 功能

```
HiDPI
├─ 虚拟屏已连接 · ID 6     （状态）
├─ 创建 HiDPI 虚拟屏 ▸
│    1280×720 / 1440×810 / 1600×900 / 1728×1117
│    1920×1080 / 2048×1152 / 2560×1440 / 2880×1620
│    ──────────
│    自定义…
├─ 断开虚拟屏
├─ 显示器（2）▸            （各屏当前分辨率，含是否 HiDPI）
├─ 打开显示器设置…
├─ 启动时自动连接          （勾选后开机即建屏，记住上次尺寸）
└─ 退出 HiDPI
```

创建后虚拟屏会出现在「系统设置 > 显示器」里，可正常拖拽排列、设为镜像或扩展。

## 命令行

| 命令 | 作用 |
|---|---|
| `hidpi list` | 列出在线显示器，显示逻辑尺寸 / 实际像素尺寸 |
| `hidpi modes <id>` | 列出某显示器的全部模式，标注 HiDPI/LoDPI 与当前项 |
| `hidpi set <id> <索引>` | 切换到指定模式（走 `CGSConfigureDisplayMode`） |
| `hidpi create` | 创建 HiDPI 虚拟显示器并保持连接 |

`create` 选项：`--size WxH`（默认 1920x1080）、`--refresh HZ`（默认 60）、`--name NAME`、`--lo`（1x）、`--seconds N`（N 秒后自动断开；不写则运行到 Ctrl-C）。

### 实测输出

```
$ hidpi list
在线显示器（1 块）

ID        名称                            逻辑            像素            标记
2         H27T22C                       1920x1080     3840x2160     主屏

$ hidpi create --size 1920x1080 --name "HiDPI Test" --seconds 9
已创建虚拟显示器
  ID        4
  逻辑      1920x1080 pt
  背衬      3840x2160 px（HiDPI 2x）
已确认 HiDPI 模式: 800x600, 960x540, 1440x810, 1920x1080, ...

$ hidpi modes 4
显示器 4 共 29 个模式，当前索引 14

索引      逻辑          实际像素          刷新      类型
0       800x600     1600x1200     60      HiDPI
2       960x540     1920x1080     60      HiDPI
...
28      1920x1080   1920x1080     60      LoDPI

$ hidpi set 4 0
已将显示器 4 切换到模式索引 0
```

## 原理

macOS 的 HiDPI = 逻辑尺寸（point）配 2 倍像素的 backing store，再由合成器降采样到面板物理分辨率。虚拟屏之所以能"无中生有"出 HiDPI，是因为系统对待虚拟显示器和真实显示器一样，会为它的模式表生成 HiDPI 变体。

用到的私有接口（全部运行时解析，不硬链接私有框架）：

- **`CGVirtualDisplay` / `CGVirtualDisplayDescriptor` / `CGVirtualDisplayMode` / `CGVirtualDisplaySettings`**（CoreGraphics 私有类）：造屏并 `applySettings` 提交模式表，`hiDPI = 1` 表示按 2x 渲染。
- **`CGSGetNumberOfDisplayModes` / `CGSGetDisplayModeDescriptionOfLength` / `CGSGetCurrentDisplayMode` / `CGSConfigureDisplayMode`**（SkyLight 私有 C 函数）：枚举与切换模式，经 `dlopen`/`dlsym` 解析。
- 显示枚举本身用公开 API（`NSScreen` + `CGDisplayCopyDisplayMode`）。

物理尺寸按 24 英寸对角线反推，色彩主坐标取自 Generic RGB Profile，使 macOS 算出合理的 DPI 与色彩描述，模式表才会被正常接受。

## 已知限制

- **虚拟屏与进程同寿命**：App 退出即断开；CLI 进程结束即断开。
- **私有 API**：`CGVirtualDisplay` 不受 Apple 支持，macOS 大版本升级可能失效。
- **不能跑在 Rosetta 下**（x86_64 转译进程拿不到这些私有服务）。
- App 是 **ad-hoc 签名**（无开发者证书、未公证）。本机构建不会被 Gatekeeper 拦；如果你把它拷给别人，对方首次打开需要右键 → 打开。
- 无 EDID 读写、无 DDC/CI、无亮度控制、无镜像/串流。

## 常驻运行（launchd）

```xml
~/Library/LaunchAgents/local.hidpi.virtual.plist
  ProgramArguments: /usr/local/bin/hidpi create --size 1920x1080 --name HiDPI
  RunAtLoad / KeepAlive: true
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.hidpi.virtual.plist
```

## 目录结构

```
hidpi/
├── Package.swift
├── LICENSE
├── README.md
├── scripts/
│   ├── build-app.sh            # 编译 → 组装 .app → 图标 → 签名 → DMG
│   └── make-icon.swift         # 程序化生成 1024px 图标
├── dist/                       # 构建产物（HiDPI.app / HiDPI-0.1.0.dmg）
└── Sources/
    ├── HDShim/                 # 私有 API 封装（C 接口）
    │   ├── include/hd.h
    │   └── hd.m
    ├── hidpi/                  # 命令行
    │   └── main.swift
    └── HiDPIMenuBar/           # 菜单栏 App（AppKit）
        └── main.swift
```

## 许可与署名

MIT License — 见 [LICENSE](LICENSE)。

私有类型的 `@interface` 声明与虚拟屏的调用方式参考自 **BetterDummy OpenSource Edition**（MIT，Copyright (c) 2021 Istvan T.），即 [waydabber/BetterDisplay 的 `opensource` 分支](https://github.com/waydabber/BetterDisplay/tree/opensource)。上游当前的 BetterDisplay 5.x 已闭源，与本项目无代码关系。
