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

  /// 常用逻辑分辨率预设
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
      button.toolTip = "HiDPI 虚拟显示器"
    }

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu

    connectAtLaunch = UserDefaults.standard.bool(forKey: kAutoCreateKey)
    if connectAtLaunch, let saved = UserDefaults.standard.string(forKey: kLastSizeKey) {
      let parts = saved.split(separator: "x").compactMap { Int($0) }
      if parts.count == 2 {
        _ = createVirtualDisplay(width: parts[0], height: parts[1])
      }
    }
    rebuildMenu()
  }

  func applicationWillTerminate(_ notification: Notification) {
    hd_release_virtual_displays()
  }

  // MARK: - 菜单

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildMenu()
  }

  private func rebuildMenu() {
    guard let menu = statusItem.menu else { return }
    menu.removeAllItems()

    let header = NSMenuItem(title: createdDisplayID == 0 ? "未连接虚拟屏" : "虚拟屏已连接 · ID \(createdDisplayID)",
                            action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())

    // 创建虚拟屏
    let createItem = NSMenuItem(title: "创建 HiDPI 虚拟屏", action: nil, keyEquivalent: "")
    let createMenu = NSMenu()
    for preset in presets {
      let item = NSMenuItem(title: "\(preset.width)×\(preset.height)",
                            action: #selector(createPreset(_:)),
                            keyEquivalent: "")
      item.target = self
      item.representedObject = "\(preset.width)x\(preset.height)"
      createMenu.addItem(item)
    }
    createMenu.addItem(.separator())
    let custom = NSMenuItem(title: "自定义…", action: #selector(createCustom), keyEquivalent: "")
    custom.target = self
    createMenu.addItem(custom)
    createItem.submenu = createMenu
    menu.addItem(createItem)

    // 断开
    let disconnect = NSMenuItem(title: "断开虚拟屏", action: #selector(disconnect), keyEquivalent: "")
    disconnect.target = self
    disconnect.isEnabled = createdDisplayID != 0
    menu.addItem(disconnect)

    menu.addItem(.separator())

    // 显示器信息
    addDisplayInfo(to: menu)

    menu.addItem(.separator())

    let settings = NSMenuItem(title: "打开显示器设置…", action: #selector(openSettings), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)

    let auto = NSMenuItem(title: "启动时自动连接", action: #selector(toggleAuto), keyEquivalent: "")
    auto.target = self
    auto.state = connectAtLaunch ? .on : .off
    menu.addItem(auto)

    menu.addItem(.separator())

    let quit = NSMenuItem(title: "退出 HiDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  private func addDisplayInfo(to menu: NSMenu) {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }
    let title = NSMenuItem(title: "显示器（\(screens.count)）", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    for screen in screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        continue
      }
      let id = CGDirectDisplayID(number.uint32Value)
      var text = "\(screen.localizedName)"
      if let mode = CGDisplayCopyDisplayMode(id) {
        text += " · \(mode.width)×\(mode.height)"
        if mode.pixelWidth == mode.width * 2 {
          text += " HiDPI"
        }
      }
      let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
      item.isEnabled = false
      submenu.addItem(item)
    }
    title.submenu = submenu
    menu.addItem(title)
  }

  // MARK: - 动作

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

// 单实例保护：已经有同 bundle id 的实例在跑就直接激活它并退出，
// 否则重复启动会叠出多块虚拟屏。
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
