//
//  HiDPI 菜单栏 App
//
//  机制：CGSConfigureDisplayMode 切模式；CGSConfigureDisplayEnabled 断开/重连激活 override
//       gamma 表做软件调光；ColorSync 切换 ICC；CGEventTap 绑定 F1/F2
//  私有 API 声明参考 BetterDummy OpenSource Edition (MIT, Copyright (c) 2021 Istvan T.)
//

import Cocoa
import Foundation
import HDShim

private struct ModeEntry {
  let index: Int
  let width: UInt32
  let height: UInt32
  let hiDPI: Bool
  let refresh: Double
}

private let kKeyBindingKey = "brightnessKeyBinding"

// MARK: - 设置窗口

final class SettingsWindowController: NSWindowController {
  private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let brightnessSlider = NSSlider(frame: .zero)
  private let brightnessLabel = NSTextField(labelWithString: "100%")
  private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let hintLabel = NSTextField(labelWithString: "勾选菜单里的「F1 / F2 调节亮度」后，可用键盘亮度键调整")

  private(set) var displayIDs: [CGDirectDisplayID] = []
  private(set) var profilePaths: [String] = [""]

  var onBrightness: ((Float) -> Void)?
  var onProfile: ((String?) -> Void)?
  var onDisplay: ((CGDirectDisplayID) -> Void)?

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "HiDPI 设置"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    buildUI()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func buildUI() {
    guard let content = window?.contentView else { return }

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)

    func row(_ title: String, _ control: NSView) -> NSStackView {
      let label = NSTextField(labelWithString: title)
      label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
      label.widthAnchor.constraint(equalToConstant: 84).isActive = true
      let rowStack = NSStackView(views: [label, control])
      rowStack.orientation = .horizontal
      rowStack.spacing = 8
      return rowStack
    }

    displayPopup.target = self
    displayPopup.action = #selector(displayChanged)
    displayPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

    brightnessSlider.minValue = 0.2
    brightnessSlider.maxValue = 1.0
    brightnessSlider.target = self
    brightnessSlider.action = #selector(brightnessChanged)
    brightnessSlider.isContinuous = true
    brightnessLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

    let brightnessRow = NSStackView(views: [brightnessSlider, brightnessLabel])
    brightnessRow.orientation = .horizontal
    brightnessRow.spacing = 8

    profilePopup.target = self
    profilePopup.action = #selector(profileChanged)
    profilePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

    hintLabel.font = NSFont.systemFont(ofSize: 11)
    hintLabel.textColor = .secondaryLabelColor
    hintLabel.lineBreakMode = .byWordWrapping
    hintLabel.maximumNumberOfLines = 3
    hintLabel.preferredMaxLayoutWidth = 340

    stack.addArrangedSubview(row("显示器", displayPopup))
    stack.addArrangedSubview(row("亮度", brightnessRow))
    stack.addArrangedSubview(row("颜色描述文件", profilePopup))
    stack.addArrangedSubview(hintLabel)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
    ])
  }

  func reload(selected displayID: CGDirectDisplayID) {
    displayIDs = NSScreen.screens.compactMap { screen in
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        .map { CGDirectDisplayID($0.uint32Value) }
    }

    displayPopup.removeAllItems()
    for id in displayIDs {
      let name = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
      }?.localizedName ?? "显示器 \(id)"
      displayPopup.addItem(withTitle: name)
    }
    if let index = displayIDs.firstIndex(of: displayID) {
      displayPopup.selectItem(at: index)
    }

    let level = hd_get_brightness(displayID)
    brightnessSlider.doubleValue = level < 0 ? 1.0 : Double(level)
    updateBrightnessLabel()

    profilePaths = [""]
    profilePopup.removeAllItems()
    profilePopup.addItem(withTitle: "系统默认")

    var paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    var count: Int32 = 0
    if hd_list_color_profiles(&paths, &count) == 0, let paths {
      defer { hd_free_profiles(paths, count) }
      for index in 0 ..< Int(count) {
        guard let cString = paths[index] else { continue }
        let path = String(cString: cString)
        profilePaths.append(path)
        profilePopup.addItem(withTitle: (path as NSString).lastPathComponent)
      }
    }

    var currentPointer = hd_current_color_profile(displayID)
    defer { if let currentPointer { free(currentPointer) } }
    if let currentPointer {
      let current = String(cString: currentPointer)
      if let index = profilePaths.firstIndex(of: current) {
        profilePopup.selectItem(at: index)
      }
    } else {
      profilePopup.selectItem(at: 0)
    }
  }

  private func updateBrightnessLabel() {
    brightnessLabel.stringValue = "\(Int((brightnessSlider.doubleValue * 100).rounded()))%"
  }

  /// 键盘亮度键调用：按步长调整并同步 UI
  func nudgeBrightness(by delta: Double) {
    let next = min(max(brightnessSlider.doubleValue + delta, brightnessSlider.minValue), brightnessSlider.maxValue)
    brightnessSlider.doubleValue = next
    updateBrightnessLabel()
    onBrightness?(Float(next))
  }

  @objc private func displayChanged() {
    let index = displayPopup.indexOfSelectedItem
    guard index >= 0, index < displayIDs.count else { return }
    onDisplay?(displayIDs[index])
  }

  @objc private func brightnessChanged() {
    updateBrightnessLabel()
    onBrightness?(Float(brightnessSlider.doubleValue))
  }

  @objc private func profileChanged() {
    let index = profilePopup.indexOfSelectedItem
    guard index >= 0, index < profilePaths.count else { return }
    let path = profilePaths[index]
    onProfile?(path.isEmpty ? nil : path)
  }
}

// MARK: - 键盘事件回调

private func brightnessKeyCallback(proxy: CGEventTapProxy,
                                   type: CGEventType,
                                   event: CGEvent,
                                   userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

  if type.rawValue == 0xFFFFFFFE || type.rawValue == 0xFFFFFFFF {
    delegate.reenableKeyTap()
    return Unmanaged.passUnretained(event)
  }

  guard let nsEvent = NSEvent(cgEvent: event),
        nsEvent.type == .systemDefined,
        nsEvent.subtype.rawValue == 8 else {
    return Unmanaged.passUnretained(event)
  }

  let keyCode = (nsEvent.data1 & 0xFFFF0000) >> 16
  let isKeyDown = (nsEvent.data1 & 0x0000FF00) >> 8 == 0x0A
  guard isKeyDown, keyCode == 2 || keyCode == 3 else {
    return Unmanaged.passUnretained(event)
  }

  // 注意：不同键盘发出的键码方向可能相反。实测本机 F1(2)=亮、F2(3)=暗，故默认反转
  let invert = UserDefaults.standard.object(forKey: "brightnessKeysInvertStandard") as? Bool ?? true
  let step: Float = 0.05
  let up = keyCode == 3
  delegate.adjustBrightness(delta: (up != invert) ? step : -step)
  return nil // 吃掉事件，避免系统同时调内建屏
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private var settingsController: SettingsWindowController?
  private var keyTap: CFMachPort?
  private var keyTapSource: CFRunLoopSource?
  private var selectedDisplay: CGDirectDisplayID = CGMainDisplayID()

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

    if UserDefaults.standard.bool(forKey: kKeyBindingKey) {
      installKeyTap()
    }

    if ProcessInfo.processInfo.environment["HIDPI_DUMP_WINDOW"] == "1" {
      openSettings()
      let window = settingsController?.window
      print("window=\(window != nil ? "ok" : "nil") size=\(window?.frame.size ?? .zero)")
      exit(0)
    }

    if ProcessInfo.processInfo.environment["HIDPI_DUMP_MENU"] == "1" {
      print("keyTap=\(keyTap != nil ? "ok" : "unavailable")")
      dump(menu: menu, depth: 0)
      exit(0)
    }

    if let value = ProcessInfo.processInfo.environment["HIDPI_BRIGHTNESS"], let level = Float(value) {
      _ = hd_set_brightness(CGMainDisplayID(), level / 100.0)
      print("brightness=\(Int(level))%")
      Thread.sleep(forTimeInterval: 6)
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
      if let sub = item.submenu { dump(menu: sub, depth: depth + 1) }
    }
  }

  // MARK: - 菜单

  private func rebuildMenu() {
    guard let menu = statusItem.menu else { return }
    menu.removeAllItems()

    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
      let id = CGDirectDisplayID(number.uint32Value)
      let item = NSMenuItem(title: "\(screen.localizedName) — \(currentModeLabel(id))", action: nil, keyEquivalent: "")
      item.submenu = displayMenu(for: id)
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    let binding = NSMenuItem(title: "F1 / F2 调节亮度", action: #selector(toggleKeyBinding), keyEquivalent: "")
    binding.target = self
    binding.state = UserDefaults.standard.bool(forKey: kKeyBindingKey) ? .on : .off
    menu.addItem(binding)

    menu.addItem(.separator())
    let quit = NSMenuItem(title: "退出 HiDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  private func displayMenu(for displayID: CGDirectDisplayID) -> NSMenu {
    let menu = NSMenu()
    let entries = modeEntries(for: displayID)
    guard !entries.isEmpty else {
      let item = NSMenuItem(title: "无法读取模式表", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return menu
    }

    let nativePixelSize = nativPanelPixelSize(displayID)
    let current = currentMode(displayID)
    let currentKey = current.map { "\($0.width)x\($0.height)x\($0.hiDPI ? 1 : 0)" } ?? ""

    let resolutionItem = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
    let resolutionMenu = NSMenu()
    let common = entries.filter { entry in
      commonSizes.contains { $0.0 == entry.width && $0.1 == entry.height }
    }
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

      let hasHiDPIVariant = common.contains {
        $0.width == entry.width && $0.height == entry.height && $0.hiDPI
      }
      var title = "\(entry.width)×\(entry.height)"
      if !hasHiDPIVariant {
        if entry.width == nativePixelSize.width && entry.height == nativePixelSize.height {
          title += "  （原生，1:1 像素）"
        } else {
          title += "  （无 HiDPI）"
        }
      }
      let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
      item.target = self
      item.tag = variant.index
      item.representedObject = NSNumber(value: displayID)
      item.state = (entry.width == current?.width && entry.height == current?.height) ? .on : .off
      resolutionMenu.addItem(item)
    }
    resolutionItem.submenu = resolutionMenu
    menu.addItem(resolutionItem)

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

    let hidpiItem = NSMenuItem(title: "启用 HiDPI", action: #selector(toggleHiDPI(_:)), keyEquivalent: "")
    hidpiItem.target = self
    hidpiItem.representedObject = NSNumber(value: displayID)
    hidpiItem.state = current?.hiDPI == true ? .on : .off
    menu.addItem(hidpiItem)

    return menu
  }

  private let commonSizes: [(UInt32, UInt32)] = [
    (1280, 800), (1440, 900), (1512, 982), (1600, 900), (1680, 1050),
    (1728, 1117), (1920, 1080), (1920, 1200), (2048, 1152), (2304, 1296),
    (2560, 1440), (2560, 1600), (2880, 1620), (3008, 1692), (3200, 1800),
    (3440, 1440), (3840, 2160),
  ]

  // MARK: - 数据

  private func modeEntries(for displayID: CGDirectDisplayID) -> [ModeEntry] {
    var byKey: [String: ModeEntry] = [:]
    for mode in rawModes(for: displayID) {
      let key = "\(mode.width)x\(mode.height)x\(mode.hiDPI)"
      if let existing = byKey[key], existing.refresh >= mode.refresh { continue }
      byKey[key] = mode
    }
    return byKey.values.sorted { lhs, rhs in
      if lhs.width != rhs.width { return lhs.width < rhs.width }
      if lhs.height != rhs.height { return lhs.height < rhs.height }
      return lhs.hiDPI && !rhs.hiDPI
    }
  }

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

  private func nativPanelPixelSize(_ displayID: CGDirectDisplayID) -> (width: UInt32, height: UInt32) {
    var best: (width: UInt32, height: UInt32) = (0, 0)
    for mode in rawModes(for: displayID) where !mode.hiDPI {
      if mode.width * mode.height > best.width * best.height {
        best = (mode.width, mode.height)
      }
    }
    return best
  }

  private func currentMode(_ displayID: CGDirectDisplayID) -> ModeEntry? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    return ModeEntry(index: -1, width: UInt32(mode.width), height: UInt32(mode.height),
                     hiDPI: mode.pixelWidth == mode.width * 2, refresh: mode.refreshRate)
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

  @objc private func toggleHiDPI(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? NSNumber else { return }
    let displayID = number.uint32Value
    guard let current = currentMode(displayID) else { return }
    let target = modeEntries(for: displayID).first {
      $0.width == current.width && $0.height == current.height && $0.hiDPI != current.hiDPI
    }
    guard let target else {
      notify(title: "没有对应的档位",
             text: "\(current.width)×\(current.height) 只有\(current.hiDPI ? " HiDPI" : " LoDPI")一种密度。")
      return
    }
    _ = hd_display_set_mode(displayID, Int32(target.index))
    rebuildMenu()
  }

  @objc private func openSettings() {
    if settingsController == nil {
      settingsController = SettingsWindowController()
      settingsController?.onBrightness = { [weak self] level in
        guard let self else { return }
        _ = hd_set_brightness(self.selectedDisplay, level)
      }
      settingsController?.onProfile = { [weak self] path in
        guard let self else { return }
        _ = path.map { hd_apply_color_profile(self.selectedDisplay, $0) }
          ?? hd_apply_color_profile(self.selectedDisplay, nil)
      }
      settingsController?.onDisplay = { [weak self] id in
        guard let self else { return }
        self.selectedDisplay = id
        self.settingsController?.reload(selected: id)
      }
    }
    selectedDisplay = CGMainDisplayID()
    settingsController?.reload(selected: selectedDisplay)
    settingsController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func toggleKeyBinding() {
    let enabled = !UserDefaults.standard.bool(forKey: kKeyBindingKey)
    UserDefaults.standard.set(enabled, forKey: kKeyBindingKey)
    if enabled {
      if !installKeyTap() {
        UserDefaults.standard.set(false, forKey: kKeyBindingKey)
        notify(title: "需要辅助功能权限",
               text: "请在「系统设置 > 隐私与安全性 > 辅助功能」里勾选 HiDPI，然后重新开启。")
        openAccessibilitySettings()
      }
    } else {
      removeKeyTap()
    }
    rebuildMenu()
  }

  // MARK: - 键盘绑定

  @discardableResult
  func installKeyTap() -> Bool {
    guard keyTap == nil else { return true }
    // NX_SYSDEFINED 在 CGEventType 里没有具名常量，rawValue 固定为 14
    let systemDefined: CGEventType = CGEventType(rawValue: 14)!
    let mask = CGEventMask(1 << systemDefined.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: brightnessKeyCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      return false
    }
    keyTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    keyTapSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  private func removeKeyTap() {
    if let tap = keyTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let source = keyTapSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    keyTap = nil
    keyTapSource = nil
  }

  func reenableKeyTap() {
    if let tap = keyTap {
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }

  func adjustBrightness(delta: Float) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let controller = self.settingsController, controller.window?.isVisible == true {
        controller.nudgeBrightness(by: Double(delta))
        return
      }
      let current = hd_get_brightness(self.selectedDisplay)
      let next = min(max((current < 0 ? 1.0 : current) + delta, 0.2), 1.0)
      _ = hd_set_brightness(self.selectedDisplay, next)
    }
  }

  private func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
