# 更新日志

## v1.0.0

首个可日常使用的版本。

**分辨率**
- 菜单栏直接列出并切换真实显示器的分辨率，单屏时扁平展示
- 刷新率独立子菜单（读原始模式表，含 24/30Hz 影院档）
- HiDPI 开关；缺 HiDPI 的尺寸标注「无 HiDPI」，原生分辨率标注「原生」
- 自定义分辨率注入：hex 路径 override + 软件断开重连激活（`scripts/add-custom-resolution.sh`）

**颜色**
- ColorSync 颜色描述文件切换，含「系统默认」
- 只接受 `mntr` + `RGB` 类型 ICC，避免抽象/灰度 profile 触发 ColorSync abort
- 唤醒后自动重放，且不会与用户操作互相覆盖

**系统**
- 合盖状态显示（`AppleClamshellState`）
- 保持屏幕常亮（`IOPMAssertion`）
- 开机自启动（LaunchAgent）、单实例保护

**CLI**
- `list` / `modes` / `set` / `cycle` / `info` / `state` / `profiles` / `profile` / `version`

**已知限制**
- 仅 Apple Silicon，macOS 12+
- ad-hoc 签名，未公证：其他机器首次打开需右键 → 打开
- HDMI 范围（Full / Limited）无系统接口，需在显示器 OSD 调整
