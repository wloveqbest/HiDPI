//
//  HiDPI 菜单栏 App
//
//  机制：CGSConfigureDisplayMode 切模式；CGSConfigureDisplayEnabled 断开/重连激活 override
//       ColorSync 切换 ICC；IOPMAssertion 防止显示器睡眠
//  私有 API 声明参考 BetterDummy OpenSource Edition (MIT, Copyright (c) 2021 Istvan T.)
//

import Cocoa
import Foundation
import HDShim
import HiDPICore

private let kSleepPreventionKey = "preventDisplaySleep"

// MARK: - 设置窗口（颜色描述文件）

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)

  private(set) var displayIDs: [CGDirectDisplayID] = []
  private(set) var profilePaths: [String] = [""]

  var onProfile: ((String?) -> Void)?
  var onDisplay: ((CGDirectDisplayID) -> Void)?

  init() {
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.title = "HiDPI 设置"
    window.isReleasedWhenClosed = false
    window.isFloatingPanel = true
    window.becomesKeyOnlyIfNeeded = false
    window.hidesOnDeactivate = false
    // 固定尺寸，避免布局把窗口撑大/缩小时产生位移
    window.setContentSize(NSSize(width: 380, height: 130))
    window.contentMinSize = NSSize(width: 380, height: 130)
    window.contentMaxSize = NSSize(width: 380, height: 130)
    window.isMovableByWindowBackground = true
    super.init(window: window)
    window.delegate = self
    buildUI()
  }

  /// 首次显示时居中，之后沿用系统记住的位置
  func present() {
    guard let window else { return }
    if let saved = UserDefaults.standard.string(forKey: "settingsWindowFrame") {
      let frame = NSRectFromString(saved)
      let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
      if onScreen && frame.width > 0 {
        window.setFrame(frame, display: true)
      } else {
        window.center()
      }
    } else {
      window.center()
    }
    showWindow(nil)
    window.makeKeyAndOrderFront(nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  func windowWillClose(_ notification: Notification) {
    // 关闭时记一次位置，拖动过程中不写盘，避免与 AppKit 的拖动收尾竞争
    if let window = notification.object as? NSWindow {
      UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "settingsWindowFrame")
    }
  }

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
      label.widthAnchor.constraint(equalToConstant: 96).isActive = true
      let rowStack = NSStackView(views: [label, control])
      rowStack.orientation = .horizontal
      rowStack.spacing = 8
      return rowStack
    }

    displayPopup.target = self
    displayPopup.action = #selector(displayChanged)
    displayPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true

    profilePopup.target = self
    profilePopup.action = #selector(profileChanged)
    profilePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true

    stack.addArrangedSubview(row("显示器", displayPopup))
    stack.addArrangedSubview(row("颜色描述文件", profilePopup))

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
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

  @objc private func displayChanged() {
    let index = displayPopup.indexOfSelectedItem
    guard index >= 0, index < displayIDs.count else { return }
    onDisplay?(displayIDs[index])
  }

  @objc private func profileChanged() {
    let index = profilePopup.indexOfSelectedItem
    guard index >= 0, index < profilePaths.count else { return }
    let path = profilePaths[index]
    onProfile?(path.isEmpty ? nil : path)
  }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private var settingsController: SettingsWindowController?
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

    if UserDefaults.standard.bool(forKey: kSleepPreventionKey) {
      _ = hd_prevent_sleep(1)
    }
    restoreColorProfile()

    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(didWake),
      name: NSWorkspace.didWakeNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil
    )

    if ProcessInfo.processInfo.environment["HIDPI_DUMP_WINDOW"] == "1" {
      openSettings()
      let window = settingsController?.window
      print("window=\(window != nil ? "ok" : "nil") frame=\(window?.frame ?? .zero)")
      print("screen=\(NSScreen.main?.visibleFrame ?? .zero)")
      exit(0)
    }

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
      if let sub = item.submenu { dump(menu: sub, depth: depth + 1) }
    }
  }

  // MARK: - 唤醒/换屏

  @objc private func didWake() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      self?.restoreColorProfile()
      self?.rebuildMenu()
    }
  }

  @objc private func screensChanged() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.restoreColorProfile()
      self?.rebuildMenu()
    }
  }

  private func restoreColorProfile() {
    let defaults = UserDefaults.standard
    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
      let id = CGDirectDisplayID(number.uint32Value)
      if let profile = defaults.string(forKey: "profile-\(id)"), !profile.isEmpty {
        _ = hd_apply_color_profile(id, profile)
      }
    }
  }

  // MARK: - 菜单

  private func rebuildMenu() {
    guard let menu = statusItem.menu else { return }
    menu.removeAllItems()

    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
      let id = CGDirectDisplayID(number.uint32Value)
      let item = NSMenuItem(title: "\(screen.localizedName) — \(DisplayCatalog.describe(DisplayCatalog.current(displayID: id)))\(DisplayCatalog.clamshellText())",
                            action: nil, keyEquivalent: "")
      item.submenu = displayMenu(for: id)
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    let sleepItem = NSMenuItem(title: "防止显示器睡眠", action: #selector(toggleSleepPrevention), keyEquivalent: "")
    sleepItem.target = self
    sleepItem.state = hd_sleep_prevented() == 1 ? .on : .off
    menu.addItem(sleepItem)

    menu.addItem(.separator())
    let quit = NSMenuItem(title: "退出 HiDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  private func displayMenu(for displayID: CGDirectDisplayID) -> NSMenu {
    let menu = NSMenu()
    let entries = DisplayCatalog.deduped(displayID: displayID)
    guard !entries.isEmpty else {
      let item = NSMenuItem(title: "无法读取模式表", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return menu
    }

    let nativePixelSize = DisplayCatalog.nativePixelSize(displayID: displayID)
    let current = DisplayCatalog.current(displayID: displayID)
    let currentKey = current.map { "\($0.width)x\($0.height)x\($0.hiDPI ? 1 : 0)" } ?? ""

    // 分辨率
    let resolutionItem = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
    let resolutionMenu = NSMenu()
    let common = DisplayCatalog.commonModes(displayID: displayID)
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

      let hasHiDPIVariant = DisplayCatalog.hasHiDPIVariant(
        width: entry.width, height: entry.height, displayID: displayID)
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

    // 刷新率
    let refreshItem = NSMenuItem(title: "刷新率", action: nil, keyEquivalent: "")
    let refreshMenu = NSMenu()
    if let current {
      let candidates = DisplayCatalog.rawModes(displayID: displayID).filter {
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

    // HiDPI 开关
    let hidpiItem = NSMenuItem(title: "启用 HiDPI", action: #selector(toggleHiDPI(_:)), keyEquivalent: "")
    hidpiItem.target = self
    hidpiItem.representedObject = NSNumber(value: displayID)
    hidpiItem.state = current?.hiDPI == true ? .on : .off
    menu.addItem(hidpiItem)

    return menu
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
    guard let current = DisplayCatalog.current(displayID: displayID) else { return }
    let target = DisplayCatalog.deduped(displayID: displayID).first {
      $0.width == current.width && $0.height == current.height && $0.hiDPI != current.hiDPI
    }
    guard let target else {
      let density = current.hiDPI ? "HiDPI" : "LoDPI"
      notify(title: "没有对应的档位",
             text: "\(current.width)×\(current.height) 只有 \(density) 一种密度。")
      return
    }
    _ = hd_display_set_mode(displayID, Int32(target.index))
    rebuildMenu()
  }

  @objc private func openSettings() {
    if settingsController == nil {
      settingsController = SettingsWindowController()
      settingsController?.onProfile = { [weak self] path in
        guard let self else { return }
        _ = path.map { hd_apply_color_profile(self.selectedDisplay, $0) }
          ?? hd_apply_color_profile(self.selectedDisplay, nil)
        UserDefaults.standard.set(path ?? "", forKey: "profile-\(self.selectedDisplay)")
      }
      settingsController?.onDisplay = { [weak self] id in
        guard let self else { return }
        self.selectedDisplay = id
        self.settingsController?.reload(selected: id)
      }
    }
    selectedDisplay = CGMainDisplayID()
    settingsController?.reload(selected: selectedDisplay)
    settingsController?.present()
  }

  @objc private func toggleSleepPrevention() {
    let enabled = !UserDefaults.standard.bool(forKey: kSleepPreventionKey)
    UserDefaults.standard.set(enabled, forKey: kSleepPreventionKey)
    if hd_prevent_sleep(enabled ? 1 : 0) != 0 {
      notify(title: "设置失败", text: "无法创建防睡眠断言。")
      UserDefaults.standard.set(false, forKey: kSleepPreventionKey)
    }
    rebuildMenu()
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
