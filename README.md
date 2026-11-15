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
| 颜色描述文件（ICC 切换） | 否 | ✅ 实测 |
| 虚拟屏（无头/串流） | 否 | 仅 CLI 保留，App 已移除 |

上限：HiDPI 背衬约 5120 像素宽。4K 面板上 `2880×1620`（5760×3240）、`3008×1692`（6016×3384）会被系统丢弃，`2560×1440` 及以下是安全的。

## 功能清单

### 菜单设计

单显示器时**扁平展示**；多显示器才收进「显示器 ▸」。菜单项带 SF Symbols 图标，状态行用次要色小字。

```
H27T22C · 1920×1080 HiDPI · 75Hz · 开盖     ← 状态行（次要色，不可点）
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

呈现层（`MenuBuilder`）与状态层（`AppDelegate`）分离：前者只决定长什么样，动作通过 `MenuActionRouter` 的闭包回传，不再有一堆 `@objc` 方法散落在 AppDelegate。

收纳原则：

| 位置 | 内容 | 理由 |
|---|---|---|
| 直接展示 | 分辨率、刷新率、HiDPI、颜色描述文件 | 高频，最多两次点击 |
| 直接展示 | 保持常亮、开机自启动 | 一次性开关 |
| 收进子菜单 | 全部分辨率档位（153 个） | 只露常见尺寸 |
| 收进子菜单 | 多显示器各自的分辨率/刷新率/HiDPI/ICC | 单屏时不出现这层 |
| 状态行 | 显示器名、模式、刷新率、合盖状态 | 只读 |

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

## 合盖 / 只用外接屏

针对"合上盖子、只用外接显示器"的用法，做了四件事（对应 BetterDisplay 的同类功能）：

| 能力 | 实现 | 说明 |
|---|---|---|
| 合盖状态感知 | `IORegistry` 的 `AppleClamshellState` | 菜单标题显示「开盖 / 已合盖」，`hidpi state` 可查 |
| 防止显示器睡眠 | `IOPMAssertion`（`PreventUserIdleDisplaySleep`） | 菜单开关，持久化；开启时 `pmset -g assertions` 能看到 `HiDPI: keep display awake` |
| 唤醒后重放设置 | `NSWorkspace.didWakeNotification` | 唤醒/换屏后延迟 2 秒重放亮度和颜色（macOS 常在这时重置） |
| 颜色持久化 | UserDefaults（按显示器 ID） | 登录启动时自动恢复上次的 ICC |

没做的部分（原版有，但对当前场景价值低）：DDC 硬件亮度（本机 I2C 写入被系统拒绝）、软件断开内建屏（你已不用内建屏）、无头虚拟屏（App 里已移除）。

## 设置窗口

菜单里的「设置…」打开一个窗口：

```
显示器       [ H27T22C  ▾ ]
颜色描述文件  [ 系统默认  ▾ ]
```

多显示器时可切换目标；选择即时生效。

## 颜色描述文件

走 ColorSync：

- 列出 `/System/Library/ColorSync/Profiles`、`/Library/ColorSync/Profiles`、`~/Library/ColorSync/Profiles` 下的 `.icc/.icm`
- 应用时调用 `ColorSyncDeviceSetCustomProfiles`，系统会在 `/Library/ColorSync/Profiles/Displays/` 生成 `<显示器>-<UUID>.icc`
- 「系统默认」= 把自定义项指回工厂 profile
- 不需要 root
- **只列「显示器类 + RGB」的 profile**（ICC 头 12–15 = `mntr`、16–19 = `RGB `）。抽象类（`abst`，如 Sepia Tone）、色彩空间类（`spac`）和灰度 profile 强设时会让 ColorSync 内部断言直接 abort（SIGABRT），`@try/@catch` 拦不住，只能在入口过滤 + 应用前二次校验
- 「系统默认」= 用 `NULL` 清除自定义项，回到工厂 profile

> 亮度调节（gamma 软件调光 + F1/F2 键绑定）已移除：gamma 是进程级的、App 退出即失效，且键拦截需要辅助功能权限，实用性不足。

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
| `hidpi info <id>` | 厂商号/型号号与 override 路径（十进制 + 十六进制） |
| `hidpi profiles` | 列出可用的颜色描述文件 |
| `hidpi profile <id> [路径\|default]` | 查看/应用颜色描述文件 |
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

## 架构

```
Sources/
  HDShim/         薄 C 层，按关注点拆成四个文件 + 一个内部头
                  ├ hd.h / hd_internal.h   公开接口 / 内部符号解析
                  ├ hd_modes.m             模式枚举、切换、断开重连
                  ├ hd_system.m            合盖状态、防睡眠、重新枚举、EDID 身份
                  └ hd_color.m             ColorSync ICC 应用/查询
  HiDPICore/      共享 Swift 模型
                  └ DisplayCatalog：模式表读取、去重、常见尺寸、原生判定、
                    密度变体查询、版本号 —— CLI 与 App 共用
  hidpi/          CLI
  HiDPIMenuBar/   菜单栏 App
                  ├ main.swift             入口 + 单实例保护
                  ├ AppDelegate.swift      状态、生命周期、副作用
                  ├ MenuBuilder.swift      菜单呈现层（图标/分组/勾选）
                  └ DisplayList.swift      NSScreen → 显示器清单
```

设计约束：
- **私有符号一律运行时解析**，符号缺失只返回错误码，不会让进程起不来
- **核心逻辑与 UI 分离**：模式表处理都在 `HiDPICore`，App 只负责菜单/窗口
- **写系统状态的能力集中在脚本**：`/Library` 写入、override 注入都在 `scripts/` 里走 `sudo`，App 保持无特权

## 针对"合盖 + 只用外接屏"的优化

这台机器没有可用的内建屏，所以整套设计按单外接屏场景裁剪：

| 优化 | 做法 | 解决什么 |
|---|---|---|
| 菜单扁平 | 单屏时不出现「显示器 ▸」层级 | 少点一次，菜单更短 |
| 合盖状态可见 | 状态行读 `AppleClamshellState` 显示「开盖 / 已合盖」 | 合盖后状态一目了然 |
| 唤醒后重放 ICC | 监听 `didWake` + 屏幕参数变化，延迟重放 | 合盖唤醒常把颜色描述文件重置 |
| 保持屏幕常亮 | `IOPMAssertion`（默认关） | 合盖使用时防止外接屏熄屏 |
| 原生/无 HiDPI 标注 | 按最大 LoDPI 模式判定面板原生分辨率 | 4K 面板上「原生 1:1」和「缺 HiDPI」不再混淆 |
| 自定义分辨率 | hex 路径 override + 软件断开重连激活 | macOS 不为第三方外接屏生成 HiDPI 档位 |
| 不碰内建屏 | 无虚拟屏、无内建亮度、无断开内建屏功能 | 减少无效代码与误触 |
| 登录后自启 | LaunchAgent `LimitLoadToSessionType = Aqua` | 登录后外接屏就绪再应用设置 |

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
    ├── HDShim/                  私有 API 封装（CGS / SLS / ColorSync / IOKit）
    ├── HiDPICore/               共享显示模型（DisplayCatalog）
    ├── hidpi/                   命令行
    └── HiDPIMenuBar/            菜单栏 App
```

## 许可与署名

MIT License — 见 [LICENSE](LICENSE)。

私有类型的 `@interface` 声明参考自 **BetterDummy OpenSource Edition**（MIT，Copyright (c) 2021 Istvan T.），即 [waydabber/BetterDisplay 的 `opensource` 分支](https://github.com/waydabber/BetterDisplay/tree/opensource)。上游当前 5.x 已闭源，与本项目无代码关系。
