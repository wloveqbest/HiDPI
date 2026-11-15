# hidpi — 开源的 macOS 分辨率工具

菜单栏里直接切换**真实显示器**的分辨率；需要系统没提供的尺寸时，注入一条 override，再软件断开/重连显示器让它生效 —— 全程不需要拔线、不需要重启、不需要付费授权。MIT 许可。

> 独立实现，不包含、不修改、不绕过任何商业软件的代码或授权校验。私有 API 声明参考了 BetterDummy 早期开源版（MIT）——详见 [许可与署名](#许可与署名)。

## 能做什么

| 能力 | 需要 root | 状态 |
|---|---|---|
| 列出真屏全部分辨率并即时切换 | 否 | ✅ 实测 |
| 注入自定义分辨率（如 2400×1350 HiDPI） | 是 | ✅ 实测生效（可选，见下文） |
| 让注入的分辨率生效（`hidpi cycle`，约黑屏 2 秒） | 否 | ✅ 实测 |
| 开机自启动 | 否 | ✅ 实测 |
| 虚拟屏（无头/串流） | 否 | 仅 CLI 保留，App 已移除 |

上限：HiDPI 背衬约 5120 像素宽。4K 面板上 `2880×1620`（5760×3240）、`3008×1692`（6016×3384）会被系统丢弃，`2560×1440` 及以下是安全的。

## 安装

```bash
open dist/HiDPI-0.1.0.dmg        # 拖进 Applications
./scripts/build-app.sh            # 或自行构建
```

菜单栏常驻、不占 Dock、单实例保护。

## 菜单

每块显示器一个子菜单，分三层，不再平铺几十个模式：

```
H27T22C — 1920×1080 HiDPI
  ├─ 分辨率 ▸        1440×900（无 HiDPI）/ 1600×900 / 1680×1050（无 HiDPI）
  │                  [x] 1920×1080 / 2048×1152 / 2304×1296 / 2560×1440
  │                  3840×2160（原生，1:1 像素）
  │                  ──────────
  │                  全部分辨率… ▸   （完整模式表，含 LoDPI/HiDPI 与刷新率）
  ├─ 刷新率 ▸        24 / 30 / 60 / 72 / [x] 75 Hz   （当前分辨率下全部刷新率）
  └─ ☑ 启用 HiDPI                      （同尺寸在 1x / 2x 间切换）
☑ 开机自启动
打开显示器设置…
退出 HiDPI
```

- **分辨率**只列常见尺寸（白名单），同一尺寸只出现一次，选档时自动沿用当前的 HiDPI 状态
- **刷新率**只列当前分辨率可用的档位
- **HiDPI** 是开关，不是重复的列表项；某尺寸没有另一种密度时会提示用脚本注入
- 分辨率项不再逐个标 HiDPI/LoDPI（密度由开关显示），只给缺少 HiDPI 变体的尺寸加注：
  - `（无 HiDPI）`：系统没为这个尺寸生成 2x 变体，开启 HiDPI 后会落到 LoDPI
  - `（原生，1:1 像素）`：面板原生分辨率，1 point = 1 pixel，本身就是最清晰的，不需要 HiDPI（HiDPI 反而要 2 倍背衬，超出面板能力）
- 列表只保留 17 个常见尺寸（白名单），冷门分辨率不再出现

## 开机自启动

菜单里的「开机自启动」写一个 LaunchAgent：

```
~/Library/LaunchAgents/pro.local.hidpi.plist
  ProgramArguments = /Applications/HiDPI.app/Contents/MacOS/hidpi
  RunAtLoad        = true
  LimitLoadToSessionType = Aqua
```

勾选时写入并 `launchctl bootstrap`，取消勾选则删除文件并 `launchctl bootout`。因为是 LSUIElement App，登录后只出现菜单栏图标，不弹窗口。

> 只对「登录」生效，不是开机前。换 App 位置（不再是 /Applications）后需要重新勾选一次，让路径更新。

## 机制：四层，每层都已验证

### 1. 切换：`CGSConfigureDisplayMode`

模式表里已有的档位，直接切，瞬时生效，无需 root。

### 2. 注入：override plist（**关键：hex 路径**）

```
/Library/Displays/Contents/Resources/Overrides/
  DisplayVendorID-4d67/DisplayProductID-2753      ← 新版 macOS 只认这一种（十六进制）
```

内容：

```xml
<key>DisplayResolutionEnabled</key><true/>
<key>scale-resolutions</key>
<array><data>AAAKAAAABaA=</data></array>   <!-- 8 字节大端 (宽,高) = 背衬像素 -->
```

网上流传的教程都写十进制（`DisplayVendorID-19815`），而 macOS 27 的 WindowServer 实际去 `stat` 的是 **十六进制** `DisplayVendorID-4d67`。这是本项目踩出来的关键差异，脚本会两份都写以兼容旧系统。

### 3. 激活：软件断开 + 重连

WindowServer 只在显示器**重新枚举**时才读 override。`SLSDetectDisplays` 和显示休眠/唤醒都不够（`fs_usage` 实测：这两种方式下 Overrides 目录零访问）。

有效的是 `CGSConfigureDisplayEnabled`：把显示器软件断开、2 秒后重连，等价于拔插线缆。这也是 BetterDisplay 里那个"屏幕会黑一下"的 activation。

### 4. 权限：需要有 root 才能写 `/Library`

App 菜单不提供注入与激活入口（避免误触黑屏），这两件事只走脚本和 CLI。

App 本身不 root，写入由 `sudo` 脚本完成（商业软件这里用的是特权 helper，本质一样）。

## 注入自定义分辨率（可选）

> 只用常见分辨率的话完全不需要这一节：`1280×720 / 1440×810 / 1600×900 / 1920×1080 / 2048×1152 / 2560×1440` 都是 macOS 原生提供的 HiDPI 档位。注入是为了拿到系统没给的尺寸（如 2400×1350），或给只有 LoDPI 的尺寸补 HiDPI 变体（如 1440×900）。这一步要 root，且注入后必须重连显示器才生效。


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

脚本特性：
- 同时写 hex 与 decimal 两份路径
- **合并**已有条目，不会冲掉上次注入的档位
- 写完自动激活，并**对比激活前后的模式表**，直接告诉你哪些档位真的出现了

```
=== 模式表变化 ===
新增档位:
  + 2400x1350 HiDPI
```

## 命令行

| 命令 | 作用 |
|---|---|
| `hidpi list` | 列出在线显示器及逻辑/像素尺寸 |
| `hidpi modes <id>` | 列出全部模式，标注 HiDPI/LoDPI 与当前项 |
| `hidpi set <id> <索引>` | 立即切换模式 |
| `hidpi cycle <id> [秒]` | 软件断开/重连显示器（激活 override） |
| `hidpi activate <id>` | 同 `cycle <id> 2` |
| `hidpi detect` | `SLSDetectDisplays`（实测不足以激活 override，仅诊断用） |
| `hidpi info <id>` | 厂商号/型号号与 override 路径（十进制 + 十六进制） |
| `hidpi create` | 虚拟屏（`--size/--refresh/--name/--lo/--seconds`） |

### 实测记录

```
$ hidpi cycle 2 2
断开显示器 2 2 秒后重连（屏幕会黑一下）…
已完成断开/重连

# 注入 2400x1350 后
$ hidpi set 2 72
已将显示器 2 切换到模式索引 72
$ hidpi list
2   H27T22C   2400x1350   4800x2700   主屏      ← HiDPI，2x 背衬
```

## 已知限制

- 私有 API 不受 Apple 支持，系统升级可能失效。
- **不能跑在 Rosetta 下**。
- 背衬宽度超过约 5120 像素的档位会被丢弃。
- 内建屏无法靠断开重连激活（链路不能动），仍需重启。
- override 按 vendor/model 生效，会影响所有同型号显示器。
- App 为 ad-hoc 签名：本机双击正常，拷给别人需右键 → 打开或 `xattr -dr com.apple.quarantine`。

## 目录结构

```
hidpi/
├── dist/                        HiDPI.app / HiDPI-0.1.0.dmg
├── scripts/
│   ├── build-app.sh             编译 → .app → 图标 → 签名 → DMG
│   ├── add-custom-resolution.sh 注入自定义分辨率（sudo）
│   ├── ddc-probe.c              DDC 只读探针（诊断用）
│   └── make-icon.swift          程序化生成图标
└── Sources/
    ├── HDShim/                  私有 API 封装（CGVirtualDisplay / CGS / SLS）
    ├── hidpi/                   命令行
    └── HiDPIMenuBar/            菜单栏 App
```

## 许可与署名

MIT License — 见 [LICENSE](LICENSE)。

私有类型的 `@interface` 声明参考自 **BetterDummy OpenSource Edition**（MIT，Copyright (c) 2021 Istvan T.），即 [waydabber/BetterDisplay 的 `opensource` 分支](https://github.com/waydabber/BetterDisplay/tree/opensource)。上游当前 5.x 已闭源，与本项目无代码关系。
