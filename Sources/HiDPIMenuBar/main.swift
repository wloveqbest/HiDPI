//
//  HiDPI 菜单栏 App
//
//  机制：CGSConfigureDisplayMode 切模式；CGSConfigureDisplayEnabled 断开/重连激活 override
//  私有 API 声明参考 BetterDummy OpenSource Edition (MIT, Copyright (c) 2021 Istvan T.)
//  详见 README.md 与 LICENSE。
//

import Cocoa
import Foundation
import HDShim

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!

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
    rebuildMenu()

    // 自检：HIDPI_DUMP_MENU=1 时打印菜单树并退出
    if ProcessInfo.processInfo.environment["HIDPI_DUMP_MENU"] == "1" {
      dump(menu: menu, depth: 0)
      exit(0)
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildMenu()
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

  // MARK: - 菜单

  private func rebuildMenu() {
    guard let menu = statusItem.menu else { return }
    menu.removeAllItems()

    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        continue
      }
      let id = CGDirectDisplayID(number.uint32Value)
      let item = NSMenuItem(title: "\(screen.localizedName) — \(currentModeLabel(id))",
                            action: nil, keyEquivalent: "")
      item.submenu = resolutionMenu(for: id)
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let redetect = NSMenuItem(title: "重新枚举显示器", action: #selector(redetectDisplays), keyEquivalent: "")
    redetect.target = self
    menu.addItem(redetect)

    let settings = NSMenuItem(title: "打开显示器设置…", action: #selector(openSettings), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)

    menu.addItem(.separator())

    let quit = NSMenuItem(title: "退出 HiDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  /// 分辨率列表：按 (宽,高,HiDPI) 去重取最高刷新率，当前档打勾
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
      if let existing = byKey[key], existing.refresh >= candidate.refresh { continue }
      byKey[key] = candidate
    }

    let entries = byKey.values.sorted { lhs, rhs in
      if lhs.width != rhs.width { return lhs.width < rhs.width }
      if lhs.height != rhs.height { return lhs.height < rhs.height }
      return lhs.hiDPI && !rhs.hiDPI
    }

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
      item.state = "\(entry.width)x\(entry.height)x\(entry.hiDPI ? 1 : 0)" == currentKey ? .on : .off
      submenu.addItem(item)
    }

    submenu.addItem(.separator())
    let activate = NSMenuItem(title: "激活（断开重连，黑屏约 2 秒）",
                              action: #selector(activateDisplay(_:)), keyEquivalent: "")
    activate.target = self
    activate.representedObject = NSNumber(value: displayID)
    submenu.addItem(activate)

    return submenu
  }

  private func currentModeLabel(_ displayID: CGDirectDisplayID) -> String {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return "未知" }
    let hidpi = mode.pixelWidth == mode.width * 2 ? " HiDPI" : ""
    return "\(mode.width)×\(mode.height)\(hidpi)"
  }

  // MARK: - 动作

  @objc private func switchMode(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? NSNumber else { return }
    if hd_display_set_mode(number.uint32Value, Int32(sender.tag)) != 0 {
      notify(title: "切换失败", text: "系统拒绝了这次模式切换。")
      return
    }
    rebuildMenu()
  }

  /// 断开再重连显示器，迫使 WindowServer 重读 override（新增分辨率后需要）
  @objc private func activateDisplay(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? NSNumber else { return }
    let result = hd_cycle_display(number.uint32Value, 2.0)
    if result != 0 {
      notify(title: "激活失败", text: "错误码 \(result)。若屏幕没有恢复，请拔插一次显示器线缆。")
    }
    rebuildMenu()
  }

  @objc private func redetectDisplays() {
    _ = hd_detect_displays()
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
