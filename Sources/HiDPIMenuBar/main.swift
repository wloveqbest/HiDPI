//
//  HiDPI 菜单栏 App
//
//  机制参考 BetterDummy OpenSource Edition (MIT, Copyright (c) 2021 Istvan T.)
//  详见 README.md 与 LICENSE。
//

import Cocoa
import Foundation
import HDShim

private let kAutoCreateKey = "autoCreateAtLaunch"
private let kLastSizeKey = "lastSize"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private var createdDisplayID: UInt32 = 0
  private var connectAtLaunch = false

  private let presets: [(width: Int, height: Int)] = [
    (1280, 720), (1440, 810), (1600, 900),
    (1728, 1117), (1920, 1080), (2048, 1152),
    (2560, 1440), (2880, 1620),
  ]

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "HiDPI")
      button.image?.isTemplate = true
      button.toolTip = "HiDPI — 快速切换显示器分辨率"
    }

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu

    connectAtLaunch = UserDefaults.standard.bool(forKey: kAutoCreateKey)
    rebuildMenu()

    // 自检：HIDPI_DUMP_MENU=1 时打印菜单树并退出，便于在无 GUI 环境下验证
    if ProcessInfo.processInfo.environment["HIDPI_DUMP_MENU"] == "1" {
      dump(menu: menu, depth: 0)
      exit(0)
    }
  }

  private func dump(menu: NSMenu, depth: Int) {
    let indent = String(repeating: "  ", count: depth)
    for item in menu.items {
      if item.isSeparatorItem {
        print("\(indent)---")
        continue
      }
      let mark = item.state == .on ? "[x] " : (item.isEnabled ? "" : "(disabled) ")
      print("\(indent)\(mark)\(item.title)")
      if let sub = item.submenu {
        dump(menu: sub, depth: depth + 1)
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    hd_release_virtual_displays()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildMenu()
  }

  // MARK: - 菜单构建

  private func rebuildMenu() {
    guard let menu = statusItem.menu else { return }
    menu.removeAllItems()

    // 1. 每块真实显示器的分辨率列表
    let screens = NSScreen.screens
    for screen in screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        continue
      }
      let id = CGDirectDisplayID(number.uint32Value)
      let title = "\(screen.localizedName) — \(currentModeLabel(id))"
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.submenu = resolutionMenu(for: id)
      menu.addItem(item)
    }

    menu.addItem(.separator())

    // 2. 虚拟屏（可选，用于无头/串流场景）
    let virtualItem = NSMenuItem(title: "虚拟屏", action: nil, keyEquivalent: "")
    let virtualMenu = NSMenu()
    let status = NSMenuItem(
      title: createdDisplayID == 0 ? "未连接" : "已连接 · ID \(createdDisplayID)",
      action: nil, keyEquivalent: ""
    )
    status.isEnabled = false
    virtualMenu.addItem(status)
    virtualMenu.addItem(.separator())
    for preset in presets {
      let item = NSMenuItem(title: "\(preset.width)×\(preset.height) HiDPI",
                            action: #selector(createPreset(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = "\(preset.width)x\(preset.height)"
      virtualMenu.addItem(item)
    }
    virtualMenu.addItem(.separator())
    let custom = NSMenuItem(title: "自定义…", action: #selector(createCustom), keyEquivalent: "")
    custom.target = self
    virtualMenu.addItem(custom)
    let disconnect = NSMenuItem(title: "断开虚拟屏", action: #selector(disconnect), keyEquivalent: "")
    disconnect.target = self
    disconnect.isEnabled = createdDisplayID != 0
    virtualMenu.addItem(disconnect)
    virtualItem.submenu = virtualMenu
    menu.addItem(virtualItem)

    menu.addItem(.separator())

    let redetect = NSMenuItem(title: "重新枚举显示器", action: #selector(redetectDisplays), keyEquivalent: "")
    redetect.target = self
    menu.addItem(redetect)

    let activate = NSMenuItem(title: "激活显示配置（屏幕会闪一下）",
                              action: #selector(activateConfiguration), keyEquivalent: "")
    activate.target = self
    menu.addItem(activate)

    let settings = NSMenuItem(title: "打开显示器设置…", action: #selector(openSettings), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)

    let auto = NSMenuItem(title: "启动时自动连接虚拟屏", action: #selector(toggleAuto), keyEquivalent: "")
    auto.target = self
    auto.state = connectAtLaunch ? .on : .off
    menu.addItem(auto)

    menu.addItem(.separator())

    let quit = NSMenuItem(title: "退出 HiDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  /// 一块显示器的分辨率列表：按 (宽,高,是否 HiDPI) 去重，取最高刷新率
  private func resolutionMenu(for displayID: CGDirectDisplayID) -> NSMenu {
    let submenu = NSMenu()
    let count = hd_display_mode_count(displayID)
    guard count > 0 else {
      let item = NSMenuItem(title: "无法读取模式表", action: nil, keyEquivalent: "")
      item.isEnabled = false
      submenu.addItem(item)
      return submenu
    }

    struct Entry {
      var index: Int
      var width: UInt32
      var height: UInt32
      var hiDPI: Bool
      var refresh: Double
    }

    var byKey: [String: Entry] = [:]
    for index in 0 ..< Int(count) {
      var mode = hd_mode_t()
      guard hd_display_mode_at(displayID, Int32(index), &mode) == 0 else { continue }
      let key = "\(mode.width)x\(mode.height)x\(mode.hiDPI)"
      let candidate = Entry(index: index, width: mode.width, height: mode.height,
                            hiDPI: mode.hiDPI == 1, refresh: mode.refreshRate)
      if let existing = byKey[key], existing.refresh >= candidate.refresh {
        continue
      }
      byKey[key] = candidate
    }

    let entries = byKey.values.sorted { lhs, rhs in
      if lhs.width != rhs.width { return lhs.width < rhs.width }
      if lhs.height != rhs.height { return lhs.height < rhs.height }
      return lhs.hiDPI && !rhs.hiDPI
    }

    // 当前模式（按 宽/高/HiDPI 匹配，不比较刷新率与索引）
    var currentKey = ""
    if let current = CGDisplayCopyDisplayMode(displayID) {
      let hidpi = current.pixelWidth == current.width * 2 ? 1 : 0
      currentKey = "\(current.width)x\(current.height)x\(hidpi)"
    }

    for entry in entries {
      var title = "\(entry.width)×\(entry.height)"
      if entry.hiDPI { title += "  HiDPI" }
      title += "  · \(Int(entry.refresh))Hz"
      let item = NSMenuItem(title: title, action: #selector(switchMode(_:)), keyEquivalent: "")
      item.target = self
      item.tag = entry.index
      item.representedObject = NSNumber(value: displayID)
      let key = "\(entry.width)x\(entry.height)x\(entry.hiDPI ? 1 : 0)"
      item.state = key == currentKey ? .on : .off
      submenu.addItem(item)
    }
    return submenu
  }

  private func currentModeLabel(_ displayID: CGDirectDisplayID) -> String {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return "未知" }
    let hidpi = mode.pixelWidth == mode.width * 2 ? " HiDPI" : ""
    return "\(mode.width)×\(mode.height)\(hidpi)"
  }

  // MARK: - 动作

  /// 直接切换真实显示器的模式（瞬时生效，不涉及虚拟屏）
  @objc private func switchMode(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? NSNumber else { return }
    let displayID = number.uint32Value
    if hd_display_set_mode(displayID, Int32(sender.tag)) != 0 {
      notify(title: "切换失败", text: "系统拒绝了这次模式切换（可能该分辨率需要重新枚举）。")
      return
    }
    rebuildMenu()
  }

  @objc private func createPreset(_ sender: NSMenuItem) {
    guard let text = sender.representedObject as? String else { return }
    let parts = text.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { return }
    _ = createVirtualDisplay(width: parts[0], height: parts[1])
  }

  @objc private func createCustom() {
    let alert = NSAlert()
    alert.messageText = "自定义虚拟屏分辨率"
    alert.informativeText = "输入逻辑分辨率（point），例如 1920x1080。背衬像素为其 2 倍。"
    alert.addButton(withTitle: "创建")
    alert.addButton(withTitle: "取消")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.stringValue = UserDefaults.standard.string(forKey: kLastSizeKey) ?? "1920x1080"
    alert.accessoryView = field

    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let parts = field.stringValue.lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] >= 320, parts[1] >= 240 else {
      notify(title: "分辨率无效", text: "请使用 WxH 格式，例如 1920x1080")
      return
    }
    _ = createVirtualDisplay(width: parts[0], height: parts[1])
  }

  @discardableResult
  private func createVirtualDisplay(width: Int, height: Int) -> Bool {
    if createdDisplayID != 0 {
      hd_release_virtual_displays()
      createdDisplayID = 0
    }
    let id = hd_create_virtual_display(UInt32(width), UInt32(height), 60, "HiDPI Display", 1)
    guard id != 0 else {
      notify(title: "创建失败", text: "系统拒绝创建虚拟显示器（可能不支持或运行在 Rosetta 下）")
      return false
    }
    createdDisplayID = UInt32(id)
    UserDefaults.standard.set("\(width)x\(height)", forKey: kLastSizeKey)
    rebuildMenu()
    return true
  }

  @objc private func disconnect() {
    hd_release_virtual_displays()
    createdDisplayID = 0
    rebuildMenu()
  }

  @objc private func toggleAuto() {
    connectAtLaunch.toggle()
    UserDefaults.standard.set(connectAtLaunch, forKey: kAutoCreateKey)
    rebuildMenu()
  }

  @objc private func redetectDisplays() {
    _ = hd_detect_displays()
    rebuildMenu()
  }

  /// 让 WindowServer 重新枚举：先请求重枚举，再让显示器休眠/唤醒一次
  @objc private func activateConfiguration() {
    _ = hd_detect_displays()
    runProcess("/usr/bin/pmset", ["displaysleepnow"])
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      self.runProcess("/usr/bin/caffeinate", ["-u", "-t", "2"])
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        self.rebuildMenu()
      }
    }
  }

  @discardableResult
  private func runProcess(_ path: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
  }

  @objc private func openSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }

  private func notify(title: String, text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}

// MARK: - 入口

// 单实例保护：已有同 bundle id 的实例在跑就激活它并退出
if let bundleID = Bundle.main.bundleIdentifier {
  let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != getpid() }
  if let running = others.first {
    running.activate(options: [])
    exit(0)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
