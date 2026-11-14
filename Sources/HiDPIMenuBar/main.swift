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

/// 模式表里的一条（按 宽/高/HiDPI 去重后，取最高刷新率）
private struct ModeEntry {
  let index: Int
  let width: UInt32
  let height: UInt32
  let hiDPI: Bool
  let refresh: Double
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!

  /// 常见分辨率白名单（逻辑尺寸）
  private let commonSizes: [(UInt32, UInt32)] = [
    (1280, 800), (1440, 900), (1512, 982), (1600, 900), (1680, 1050),
    (1728, 1117), (1920, 1080), (1920, 1200), (2048, 1152), (2304, 1296),
    (2560, 1440), (2560, 1600), (2880, 1620), (3008, 1692), (3200, 1800),
    (3440, 1440), (3840, 2160),
  ]

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "HiDPI")
      button.image?.isTemplate = true
      button.toolTip = "HiDPI — 快速调整显示器"
    }

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
    rebuildMenu()

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
      item.submenu = displayMenu(for: id)
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let settings = NSMenuItem(title: "打开显示器设置…", action: #selector(openSettings), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)

    let quit = NSMenuItem(title: "退出 HiDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  /// 单块显示器的菜单：分辨率 / 刷新率 / HiDPI 开关 / 激活
  private func displayMenu(for displayID: CGDirectDisplayID) -> NSMenu {
    let menu = NSMenu()
    let entries = modeEntries(for: displayID)

    guard !entries.isEmpty else {
      let item = NSMenuItem(title: "无法读取模式表", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return menu
    }

    let current = currentMode(displayID)
    let currentKey = current.map { "\($0.width)x\($0.height)x\($0.hiDPI ? 1 : 0)" } ?? ""

    // 1) 分辨率（只放常见尺寸，完整列表收到次级菜单）
    let resolutionItem = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
    let resolutionMenu = NSMenu()

    let common = entries.filter { entry in
      commonSizes.contains { $0.0 == entry.width && $0.1 == entry.height }
    }
    // 同一尺寸只列一次；选档时沿用当前的 HiDPI 状态
    var seenSizes = Set<String>()
    for entry in common {
      let sizeKey = "\(entry.width)x\(entry.height)"
      if seenSizes.contains(sizeKey) { continue }
      seenSizes.insert(sizeKey)

      let wantHiDPI = current?.hiDPI ?? true
      let sameRate = common.first {
        $0.width == entry.width && $0.height == entry.height
          && $0.hiDPI == wantHiDPI && Int($0.refresh.rounded()) == Int((current?.refresh ?? 0).rounded())
      }
      let variant = sameRate
        ?? common.first { $0.width == entry.width && $0.height == entry.height && $0.hiDPI == wantHiDPI }
        ?? entry

      // 该尺寸若没有 HiDPI 变体，明确标出来（否则开 HiDPI 时会静默落到 LoDPI）
      let hasHiDPIVariant = common.contains {
        $0.width == entry.width && $0.height == entry.height && $0.hiDPI
      }
      var title = "\(entry.width)×\(entry.height)"
      if !hasHiDPIVariant {
        title += "  （无 HiDPI）"
      }
      let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
      item.target = self
      item.tag = variant.index
      item.representedObject = NSNumber(value: displayID)
      item.state = (entry.width == current?.width && entry.height == current?.height) ? .on : .off
      resolutionMenu.addItem(item)
    }

    if !common.isEmpty {
      resolutionMenu.addItem(.separator())
    }
    let allItem = NSMenuItem(title: "全部分辨率…", action: nil, keyEquivalent: "")
    let allMenu = NSMenu()
    for entry in entries {
      var title = "\(entry.width)×\(entry.height)"
      if entry.hiDPI { title += "  HiDPI" }
      title += "  · \(Int(entry.refresh))Hz"
      let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
      item.target = self
      item.tag = entry.index
      item.representedObject = NSNumber(value: displayID)
      item.state = "\(entry.width)x\(entry.height)x\(entry.hiDPI ? 1 : 0)" == currentKey ? .on : .off
      allMenu.addItem(item)
    }
    allItem.submenu = allMenu
    resolutionMenu.addItem(allItem)

    resolutionItem.submenu = resolutionMenu
    menu.addItem(resolutionItem)

    // 2) 刷新率（当前分辨率下可用的刷新率）
    let refreshItem = NSMenuItem(title: "刷新率", action: nil, keyEquivalent: "")
    let refreshMenu = NSMenu()
    if let current {
      let candidates = rawModes(for: displayID).filter {
        $0.width == current.width && $0.height == current.height && $0.hiDPI == current.hiDPI
      }
      let rates = Set(candidates.map { Int($0.refresh.rounded()) }).sorted()
      for rate in rates {
        if let match = candidates.first(where: { Int($0.refresh.rounded()) == rate }) {
          let item = NSMenuItem(title: "\(rate) Hz", action: #selector(selectMode(_:)), keyEquivalent: "")
          item.target = self
          item.tag = match.index
          item.representedObject = NSNumber(value: displayID)
          item.state = rate == Int(current.refresh.rounded()) ? .on : .off
          refreshMenu.addItem(item)
        }
      }
    }
    if refreshMenu.items.isEmpty {
      let item = NSMenuItem(title: "当前分辨率只有一个刷新率", action: nil, keyEquivalent: "")
      item.isEnabled = false
      refreshMenu.addItem(item)
    }
    refreshItem.submenu = refreshMenu
    menu.addItem(refreshItem)

    // 3) HiDPI 开关
    let hidpiItem = NSMenuItem(title: "启用 HiDPI", action: #selector(toggleHiDPI(_:)), keyEquivalent: "")
    hidpiItem.target = self
    hidpiItem.representedObject = NSNumber(value: displayID)
    hidpiItem.state = current?.hiDPI == true ? .on : .off
    menu.addItem(hidpiItem)

    menu.addItem(.separator())

    // 4) 让新注入的分辨率生效：WindowServer 只在显示器重连时才重读 override
    let activate = NSMenuItem(title: "应用新分辨率（重连显示器，黑屏约 2 秒）",
                              action: #selector(activateDisplay(_:)), keyEquivalent: "")
    activate.target = self
    activate.representedObject = NSNumber(value: displayID)
    menu.addItem(activate)

    return menu
  }

  // MARK: - 数据

  /// 去重后的模式列表：同一 (宽,高,HiDPI) 只保留最高刷新率
  private func modeEntries(for displayID: CGDirectDisplayID) -> [ModeEntry] {
    let count = hd_display_mode_count(displayID)
    guard count > 0 else { return [] }

    var byKey: [String: ModeEntry] = [:]
    for index in 0 ..< Int(count) {
      var mode = hd_mode_t()
      guard hd_display_mode_at(displayID, Int32(index), &mode) == 0 else { continue }
      let key = "\(mode.width)x\(mode.height)x\(mode.hiDPI)"
      let candidate = ModeEntry(index: index, width: mode.width, height: mode.height,
                                hiDPI: mode.hiDPI == 1, refresh: mode.refreshRate)
      if let existing = byKey[key], existing.refresh >= candidate.refresh { continue }
      byKey[key] = candidate
    }

    return byKey.values.sorted { lhs, rhs in
      if lhs.width != rhs.width { return lhs.width < rhs.width }
      if lhs.height != rhs.height { return lhs.height < rhs.height }
      return lhs.hiDPI && !rhs.hiDPI
    }
  }

  /// 原始模式表（不去重），刷新率菜单要用它，否则只能看到最高刷新率那一档
  private func rawModes(for displayID: CGDirectDisplayID) -> [ModeEntry] {
    let count = hd_display_mode_count(displayID)
    guard count > 0 else { return [] }
    var modes: [ModeEntry] = []
    for index in 0 ..< Int(count) {
      var mode = hd_mode_t()
      guard hd_display_mode_at(displayID, Int32(index), &mode) == 0 else { continue }
      modes.append(ModeEntry(index: index, width: mode.width, height: mode.height,
                             hiDPI: mode.hiDPI == 1, refresh: mode.refreshRate))
    }
    return modes
  }

  private func currentMode(_ displayID: CGDirectDisplayID) -> ModeEntry? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    let hiDPI = mode.pixelWidth == mode.width * 2
    return ModeEntry(index: -1, width: UInt32(mode.width), height: UInt32(mode.height),
                     hiDPI: hiDPI, refresh: mode.refreshRate)
  }

  private func currentModeLabel(_ displayID: CGDirectDisplayID) -> String {
    guard let current = currentMode(displayID) else { return "未知" }
    return "\(current.width)×\(current.height)\(current.hiDPI ? " HiDPI" : "")"
  }

  // MARK: - 动作

  @objc private func selectMode(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? NSNumber else { return }
    if hd_display_set_mode(number.uint32Value, Int32(sender.tag)) != 0 {
      notify(title: "切换失败", text: "系统拒绝了这次模式切换。")
      return
    }
    rebuildMenu()
  }

  /// 在相同逻辑尺寸下切换到有/无 HiDPI 的档位
  @objc private func toggleHiDPI(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? NSNumber else { return }
    let displayID = number.uint32Value
    guard let current = currentMode(displayID) else { return }

    let target = modeEntries(for: displayID).first {
      $0.width == current.width && $0.height == current.height && $0.hiDPI != current.hiDPI
    }
    guard let target else {
      notify(title: "没有对应的档位",
             text: "\(current.width)×\(current.height) 只有\(current.hiDPI ? " HiDPI" : " LoDPI")一种密度。\n"
               + "需要另一种密度的话，先用脚本注入:\n"
               + "add-custom-resolution.sh <id> \(current.width)x\(current.height)")
      return
    }
    if hd_display_set_mode(displayID, Int32(target.index)) != 0 {
      notify(title: "切换失败", text: "系统拒绝了这次模式切换。")
      return
    }
    rebuildMenu()
  }

  @objc private func activateDisplay(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? NSNumber else { return }
    let result = hd_cycle_display(number.uint32Value, 2.0)
    if result != 0 {
      notify(title: "重连失败", text: "错误码 \(result)。若屏幕没有恢复，请拔插一次显示器线缆。")
    }
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

// 单实例保护
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
