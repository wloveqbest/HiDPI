# hidpi — 开源的 macOS 分辨率切换器

菜单栏里直接列出**真实显示器**的分辨率，点一下即时切换（`CGSConfigureDisplayMode`），不创建任何虚拟屏。另外提供一个可选的虚拟屏功能和一套自定义分辨率注入脚本。

这是 BetterDisplay / BetterDummy 最核心能力的独立开源实现，MIT 许可，**不需要付费授权**。

> 独立实现，不包含、不修改、不绕过任何商业软件的代码或授权校验。机制参考了 BetterDummy 早期开源版（MIT）——详见 [许可与署名](#许可与署名)。

## 它能做什么

| 能力 | 是否需要 root | 状态 |
|---|---|---|
| 列出真屏所有分辨率并**即时切换** | 否 | ✅ 已实测 |
| 新增系统没提供的自定义分辨率（如 4K 屏上的 1920×1080 HiDPI） | **是** | ✅ 脚本已备（`sudo` 运行） |
| 创建 HiDPI 虚拟屏（无头 / 串流 / 录屏用） | 否 | ✅ 已实测 |
| EDID 改写、DDC 亮度、镜像串流 | — | ❌ 不做 |

## 安装

```bash
open dist/HiDPI-0.1.0.dmg        # 拖进 Applications
# 或自己构建：
./scripts/build-app.sh            # 产出 dist/HiDPI.app + dist/HiDPI-0.1.0.dmg
```

App 只出现在菜单栏（`LSUIElement`，不占 Dock），有单实例保护。

## 菜单结构

```
H27T22C — 2560×1440
  ├─ 400×300  HiDPI · 75Hz
  ├─ 640×480  HiDPI · 75Hz
  ├─ 640×480  · 75Hz
  ├─ …
  ├─ 1920×1080  HiDPI · 75Hz
  ├─ 2560×1440  HiDPI · 75Hz
  └─ [x] 2560×1440  · 75Hz        ← 当前模式打勾
虚拟屏 ▸  1280×720 … 2880×1620 / 自定义… / 断开
重新枚举显示器
激活显示配置（屏幕会闪一下）
打开显示器设置…
启动时自动连接虚拟屏
退出 HiDPI
```

同一分辨率只列一次（取最高刷新率），HiDPI 档位带标记，当前模式打勾。

## 为什么"直接切换"和"新增分辨率"是两回事

macOS 每个显示器维护一张**模式表**，系统偏好设置里能选的档位就是它的子集。所以：

1. **表里已有的档位** → 直接用 `CGSConfigureDisplayMode` 切，瞬时生效，无需 root。你的显示器日常能选的那些（包括 HiDPI）都属于这一类。
2. **表里没有的档位** → 必须先让 macOS 把新档位加进模式表，再切。BetterDisplay 的 *Flexible Scaling* 走的就是这条路：往下面这个文件写一个 override plist，然后强制重新枚举：

```
/Library/Displays/Contents/Resources/Overrides/
  DisplayVendorID-<vendor>/DisplayProductID-<product>
```

plist 里关键的两项：

```xml
<key>DisplayResolutionEnabled</key><true/>
<key>scale-resolutions</key>
<array>
  <!-- 每项 8 字节：大端 uint32 宽 + uint32 高，放的是「背衬像素」尺寸 -->
  <data>AAAPAAAACHA=</data>   <!-- 0x00000F00 × 0x00000870 = 3840×2160，即 1920×1080 HiDPI -->
</array>
```

写进去之后 macOS 不会立即重读，需要重新枚举显示器（拔插线缆、重启，或调私有的 `SLSDetectDisplays`）。这一整套要 root —— 这正是 BetterDisplay 会装一个特权 helper 的原因。

## 新增自定义分辨率

完整流程已封装，**需要你自己在终端跑一次 `sudo`**（本机 `sudo` 要密码，我无法代跑）：

```bash
swift build -c release                          # 先构建 CLI

# 1. 先看要写什么（不需要 root）
./scripts/add-custom-resolution.sh 2 1920x1080 1600x900 --dry-run

# 2. 真正写入 + 自动激活（会提示密码，屏幕会闪一下）
./scripts/add-custom-resolution.sh 2 1920x1080 1600x900

# 3. 回滚
./scripts/add-custom-resolution.sh 2 --remove
```

脚本做四件事（对应 BetterDisplay 的四层）：

1. 写 `scale-resolutions` 到 `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<v>/DisplayProductID-<p>`
2. 打开全局开关 `defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool YES`
3. 调 `hidpi activate` 强制重新枚举（`SLSDetectDisplays` + 显示器休眠/唤醒）
4. **前后对比模式表**，直接告诉你新档位有没有出现：

```
=== 模式表变化 ===
新增档位:
  + 1920x1080 HiDPI
```

如果没有新增档位，说明该 macOS 版本没采信 override，需要拔插线缆或重启。加 `--no-activate` 可跳过第 3 步自行控制时机。

⚠️ override 按 **vendor/model** 生效，会同时影响所有同型号显示器。

## 命令行

| 命令 | 作用 |
|---|---|
| `hidpi list` | 列出在线显示器及逻辑/像素尺寸 |
| `hidpi modes <id>` | 列出某显示器全部模式，标注 HiDPI/LoDPI 与当前项 |
| `hidpi set <id> <索引>` | 立即切换模式 |
| `hidpi info <id>` | 打印厂商号/型号号与 override 路径 |
| `hidpi detect` | 让系统重新枚举显示器（`SLSDetectDisplays`） |
| `hidpi activate` | 激活 override：重枚举 + 显示器休眠唤醒（`--no-sleep` 可跳过休眠） |
| `hidpi create` | 创建 HiDPI 虚拟屏（`--size/--refresh/--name/--lo/--seconds`） |

### 实测

```
$ hidpi modes 2 | head -4
显示器 2 共 61 个模式，当前索引 57

索引      逻辑          实际像素          刷新      类型
0       400x300     800x600       75      HiDPI

$ hidpi set 2 1
已将显示器 2 切换到模式索引 1        # 真屏 2560×1440 → 800×600 HiDPI，瞬时生效
```

## 原理

- **切换**：`CGSGetNumberOfDisplayModes` / `CGSGetDisplayModeDescriptionOfLength` / `CGSGetCurrentDisplayMode` / `CGSConfigureDisplayMode`（SkyLight 私有 C 函数，`dlopen`+`dlsym` 运行时解析）。
- **新增**：override plist 的 `scale-resolutions`，配合 `SLSDetectDisplays` 触发重新枚举。
- **虚拟屏**（可选）：`CGVirtualDisplay` + `CGVirtualDisplayDescriptor` + `CGVirtualDisplaySettings`（CoreGraphics 私有类），`hiDPI = 1` 即按 2x 渲染。
- 显示枚举本身用公开 API（`NSScreen` + `CGDisplayCopyDisplayMode`），不依赖私有符号。

## 已知限制

- 私有 API 不受 Apple 支持，macOS 大版本升级可能失效。
- **不能跑在 Rosetta 下**。
- 自定义分辨率需要 root；macOS 27 上 override 是否仍被采信未经我实测（本机无法免密提权），脚本按经典机制生成，理论上一致。
- App 为 ad-hoc 签名（未公证）：本机双击正常，拷给别人需右键 → 打开，或 `xattr -dr com.apple.quarantine /Applications/HiDPI.app`。

## 目录结构

```
hidpi/
├── dist/                       HiDPI.app / HiDPI-0.1.0.dmg
├── scripts/
│   ├── build-app.sh            编译 → 组装 .app → 图标 → 签名 → DMG
│   ├── add-custom-resolution.sh 注入自定义分辨率（sudo）
│   └── make-icon.swift         程序化生成图标
└── Sources/
    ├── HDShim/                 私有 API 封装（C 接口）
    ├── hidpi/                  命令行
    └── HiDPIMenuBar/           菜单栏 App
```

## 许可与署名

MIT License — 见 [LICENSE](LICENSE)。

私有类型的 `@interface` 声明与虚拟屏调用方式参考自 **BetterDummy OpenSource Edition**（MIT，Copyright (c) 2021 Istvan T.），即 [waydabber/BetterDisplay 的 `opensource` 分支](https://github.com/waydabber/BetterDisplay/tree/opensource)。上游当前 5.x 已闭源，与本项目无代码关系。
