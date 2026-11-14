# hidpi — 开源的 macOS HiDPI 命令行工具

用 macOS 私有 `CGVirtualDisplay` API 在内存里造一块 **2x 背衬的虚拟显示器**，从而在任意 Mac 上获得 HiDPI 分辨率选项。这是 BetterDisplay / BetterDummy 最核心的那部分能力，本项目用约 600 行 Swift + ObjC 独立实现，MIT 许可，不需要任何付费授权。

> 本项目是**独立实现**，不包含、不修改、不绕过任何商业软件的代码或授权校验。机制参考了 BetterDummy 早期开源版（MIT）——详见 [许可与署名](#许可与署名)。

## 功能

| 命令 | 作用 |
|---|---|
| `hidpi list` | 列出在线显示器，显示逻辑尺寸 / 实际像素尺寸 |
| `hidpi modes <id>` | 列出某显示器的全部模式，标注 HiDPI/LoDPI 与当前项 |
| `hidpi set <id> <索引>` | 切换到指定模式（走 `CGSConfigureDisplayMode`） |
| `hidpi create` | 创建 HiDPI 虚拟显示器并保持连接 |

`create` 支持的选项：

| 选项 | 说明 |
|---|---|
| `--size WxH` | 逻辑分辨率，默认 `1920x1080` |
| `--refresh HZ` | 刷新率，默认 `60` |
| `--name NAME` | 显示器名称，默认 `HiDPI Display` |
| `--lo` | 创建 1x（非 HiDPI）显示 |
| `--seconds N` | 运行 N 秒后自动断开；不写则运行到 Ctrl-C |

## 构建

需要 macOS 12+ 与 Swift 5.9+（只装 Command Line Tools 即可，不需要完整 Xcode）。

```bash
cd hidpi
swift build -c release
cp .build/release/hidpi /usr/local/bin/     # 可选：装进 PATH
```

## 实测输出

```
$ hidpi list
在线显示器（1 块）

ID        名称                            逻辑            像素            标记
2         H27T22C                       1920x1080     3840x2160     主屏
```

```
$ hidpi create --size 1920x1080 --name "HiDPI Test" --seconds 9
已创建虚拟显示器
  ID        4
  名称      HiDPI Test
  逻辑      1920x1080 pt
  背衬      3840x2160 px（HiDPI 2x）
  刷新率    60 Hz

下一步:
  hidpi modes 4                 查看可用模式
  hidpi set 4 <索引>            切换模式
  系统设置 > 显示器 > 为该虚拟屏选择 HiDPI 档位

已确认 HiDPI 模式: 800x600, 960x540, 1440x810, 1920x1080, ...

9 秒后自动断开…
```

```
$ hidpi modes 4
显示器 4 共 29 个模式，当前索引 14

索引      逻辑          实际像素          刷新      类型
0       800x600     1600x1200     60      HiDPI
1       800x600     800x600       60      LoDPI
2       960x540     1920x1080     60      HiDPI
...
27      960x540     1920x1080     60      HiDPI
28      1920x1080   1920x1080     60      LoDPI
```

```
$ hidpi set 4 0
已将显示器 4 切换到模式索引 0
```

## 原理

macOS 的 HiDPI = 逻辑尺寸（point）配 2 倍像素的 backing store，再由合成器降采样到面板物理分辨率。虚拟屏之所以能"无中生有"出 HiDPI，是因为系统对待虚拟显示器和真实显示器一样，会为它的模式表生成 HiDPI 变体。

本项目用到的私有接口（全部在运行时解析，不硬链接私有框架）：

- **`CGVirtualDisplay` / `CGVirtualDisplayDescriptor` / `CGVirtualDisplayMode` / `CGVirtualDisplaySettings`**（CoreGraphics 私有类）：造屏并 `applySettings` 提交模式表，`hiDPI = 1` 表示该屏按 2x 渲染。
- **`CGSGetNumberOfDisplayModes` / `CGSGetDisplayModeDescriptionOfLength` / `CGSGetCurrentDisplayMode` / `CGSConfigureDisplayMode`**（SkyLight 私有 C 函数）：枚举模式与切换模式，经 `dlopen`/`dlsym` 解析。
- 显示枚举本身用公开 API（`NSScreen` + `CGDisplayCopyDisplayMode`），不依赖私有符号。

物理尺寸按 24 英寸对角线反推，色彩主坐标取自 Generic RGB Profile，使 macOS 算出合理的 DPI 与色彩描述，模式表才会被正常接受。

## 已知限制

- **虚拟屏与进程同寿命**：进程退出即断开。要常驻请用 launchd，或自己包一层菜单栏 App。
- **私有 API**：`CGVirtualDisplay` 不受 Apple 支持，macOS 大版本升级可能失效或改变行为。
- **不能跑在 Rosetta 下**（x86_64 转译进程拿不到这些私有服务）。
- 无 EDID 读写、无 DDC/CI、无亮度控制、无镜像/串流——这些需要 root 助手或额外协议实现，本项目刻意不做。
- 虚拟屏不会自动成为主屏，也不自动镜像到真实显示器；先在"系统设置 > 显示器"里安排位置。

## 常驻运行（可选）

`~/Library/LaunchAgents/local.hidpi.virtual.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.hidpi.virtual</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/hidpi</string>
    <string>create</string>
    <string>--size</string>
    <string>1920x1080</string>
    <string>--name</string>
    <string>HiDPI</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
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
└── Sources/
    ├── HDShim/
    │   ├── include/hd.h        # 稳定的 C 接口
    │   └── hd.m                # 私有 API 封装（CGVirtualDisplay + CGS）
    └── hidpi/
        └── main.swift          # CLI：list / modes / set / create
```

## 许可与署名

MIT License — 见 [LICENSE](LICENSE)。

私有类型的 `@interface` 声明与虚拟屏的调用方式参考自 **BetterDummy OpenSource Edition**（MIT，Copyright (c) 2021 Istvan T.），即 [waydabber/BetterDisplay 的 `opensource` 分支](https://github.com/waydabber/BetterDisplay/tree/opensource)。上游当前的 BetterDisplay 5.x 已闭源，与本项目无代码关系。
