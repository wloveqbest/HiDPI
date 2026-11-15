//
//  AppDelegate.swift — 菜单栏 App 主体
//
//  菜单设计：
//    单显示器 → 分辨率/刷新率/HiDPI 直接摆在顶层，减少一层嵌套
//    多显示器 → 收进「显示器 ▸」子菜单，顶层只留全局项
//

import Cocoa
import Foundation
import HDShim
import HiDPICore

private let kSleepPreventionKey = "preventDisplaySleep"
private let kLaunchAtLoginKey = "launchAtLogin"
private let launchAgentLabel = "pro.local.hidpi"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private var settingsController: SettingsWindowController?
  private var selectedDisplay: CGDirectDisplayID = CGMainDisplayID()

  // MARK: - 生命周期

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
      exit(0)
    }

    if ProcessInfo.processInfo.environment["HIDPI_DUMP_MENU"] == "1" {
      dump(menu: menu, depth: 0)
      exit(0)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    _ = hd_prevent_sleep(0)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildMenu()
  }

  // MARK: - 菜单构建

  private func rebuildMenu() {
    guard let menu = statusItem.menu else { return }
    menu.removeAllItems()

    let displays = DisplayCatalog.attachedDisplays()

    // 顶部状态行（不可点）
    let header = NSMenuItem(title: headerText(displays: displays), action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())

    if displays.count == 1, let single = displays.first {
      for item in displayItems(for: single.id) {
        menu.addItem(item)
      }
    } else {
      let displaysMenu = NSMenuItem(title: "显示器（\(displays.count)）", action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      for display in displays {
        let displayItem = NSMenuItem(
          title: "\(display.name) — \(DisplayCatalog.describe(DisplayCatalog.current(displayID: display.id)))",
          action: nil, keyEquivalent: ""
        )
        let inner = NSMenu()
        for item in displayItems(for: display.id) {
          inner.addItem(item)
        }
        displayItem.submenu = inner
        submenu.addItem(displayItem)
      }
      displaysMenu.submenu = submenu
      menu.addItem(displaysMenu)
    }

    menu.addItem(.separator())

    let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    let sleepItem = NSMenuItem(title: "防止显示器睡眠", action: #selector(toggleSleepPrevention), keyEquivalent: "")
    sleepItem.target = self
    sleepItem.state = hd_sleep_prevented() == 1 ? .on : .off
    menu.addItem(sleepItem)

    let launchItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    launchItem.target = self
    launchItem.state = launchAgentExists() ? .on : .off
    menu.addItem(launchItem)

    menu.addItem(.separator())
    let quit = NSMenuItem(title: "退出 HiDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  private func headerText(displays: [(id: CGDirectDisplayID, name: String)]) -> String {
    guard let first = displays.first else { return "没有检测到显示器" }
    let mode = DisplayCatalog.describe(DisplayCatalog.current(displayID: first.id))
    let name = displays.count == 1 ? first.name : "\(displays.count) 块显示器"
    return "\(name) · \(mode)\(DisplayCatalog.clamshellText())"
  }

  /// 单块显示器的可操作项：分辨率 / 刷新率 / HiDPI
  private func displayItems(for displayID: CGDirectDisplayID) -> [NSMenuItem] {
    let entries = DisplayCatalog.deduped(displayID: displayID)
    guard !entries.isEmpty else {
      let item = NSMenuItem(title: "无法读取模式表", action: nil, keyEquivalent: "")
      item.isEnabled = false
      return [item]
    }

    let nativePixelSize = DisplayCatalog.nativePixelSize(displayID: displayID)
    let current = DisplayCatalog.current(displayID: displayID)

    // 分辨率
    let resolutionItem = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
    let resolutionMenu = NSMenu()
    let common = DisplayCatalog.commonModes(displayID: displayID)
    var seenSizes = Set<String>()
    for entry in common {
      if seenSizes.contains(entry.sizeKey) { continue }
      seenSizes.insert(entry.sizeKey)

      let wantHiDPI = current?.hiDPI ?? true
      let sameRate = common.first {
        $0.width == entry.width && $0.height == entry.height
          && $0.hiDPI == wantHiDPI && Int($0.refresh.rounded()) == Int((current?.refresh ?? 0).rounded())
      }
      let variant = sameRate
        ?? common.first { $0.width == entry.width && $0.height == entry.height && $0.hiDPI == wantHiDPI }
        ?? entry

      let hasHiDPI = DisplayCatalog.hasHiDPIVariant(width: entry.width, height: entry.height,
                                                    displayID: displayID)
      var title = "\(entry.width)×\(entry.height)"
      if !hasHiDPI {
        let isNative = entry.width == nativePixelSize.width && entry.height == nativePixelSize.height
        title += isNative ? "  （原生，1:1 像素）" : "  （无 HiDPI）"
      }

      let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
      item.target = self
      item.tag = variant.index
      item.representedObject = NSNumber(value: displayID)
      item.state = (entry.width == current?.width && entry.height == current?.height) ? .on : .off
      resolutionMenu.addItem(item)
    }
    resolutionItem.submenu = resolutionMenu

    // 刷新率
    let refreshItem = NSMenuItem(title: "刷新率", action: nil, keyEquivalent: "")
    let refreshMenu = NSMenu()
    if let current {
      let candidates = DisplayCatalog.rawModes(displayID: displayID).filter {
        $0.width == current.width && $0.height == current.height && $0.hiDPI == current.hiDPI
      }
      let rates = Set(candidates.map { Int($0.refresh.rounded()) }).sorted()
      for rate in rates {
        guard let match = candidates.first(where: { Int($0.refresh.rounded()) == rate }) else { continue }
        let item = NSMenuItem(title: "\(rate) Hz", action: #selector(selectMode(_:)), keyEquivalent: "")
        item.target = self
        item.tag = match.index
        item.representedObject = NSNumber(value: displayID)
        item.state = rate == Int(current.refresh.rounded()) ? .on : .off
        refreshMenu.addItem(item)
      }
    }
    if refreshMenu.items.isEmpty {
      let item = NSMenuItem(title: "只有一个刷新率", action: nil, keyEquivalent: "")
      item.isEnabled = false
      refreshMenu.addItem(item)
    }
    refreshItem.submenu = refreshMenu

    // HiDPI 开关
    let hidpiItem = NSMenuItem(title: "启用 HiDPI", action: #selector(toggleHiDPI(_:)), keyEquivalent: "")
    hidpiItem.target = self
    hidpiItem.representedObject = NSNumber(value: displayID)
    hidpiItem.state = current?.hiDPI == true ? .on : .off

    return [resolutionItem, refreshItem, hidpiItem]
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

  // MARK: - 唤醒 / 屏幕变化

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
    for display in DisplayCatalog.attachedDisplays() {
      if let profile = defaults.string(forKey: "profile-\(display.id)"), !profile.isEmpty {
        _ = hd_apply_color_profile(display.id, profile)
      }
    }
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
      notify(title: "没有对应的档位", text: "\(current.width)×\(current.height) 只有 \(density) 一种密度。")
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

  // MARK: - 开机自启动（LaunchAgent）

  private var launchAgentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
  }

  private func launchAgentExists() -> Bool {
    FileManager.default.fileExists(atPath: launchAgentURL.path)
  }

  @objc private func toggleLaunchAtLogin() {
    if launchAgentExists() {
      disableLaunchAtLogin()
    } else {
      enableLaunchAtLogin()
    }
    rebuildMenu()
  }

  private func enableLaunchAtLogin() {
    guard let executable = Bundle.main.executablePath else { return }
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(launchAgentLabel)</string>
      <key>ProgramArguments</key><array><string>\(executable)</string></array>
      <key>RunAtLoad</key><true/>
      <key>LimitLoadToSessionType</key><string>Aqua</string>
      <key>ProcessType</key><string>Interactive</string>
    </dict>
    </plist>
    """
    try? FileManager.default.createDirectory(
      at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
    launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
  }

  private func disableLaunchAtLogin() {
    try? FileManager.default.removeItem(at: launchAgentURL)
    // 当前进程若不是由该 job 启动，才卸载，避免把自己杀掉
    let current = launchctlOutput(["print", "gui/\(getuid())/\(launchAgentLabel)"]) ?? ""
    let pidLine = current.split(separator: "\n").first { $0.contains("pid = ") }
    let jobPID = pidLine.flatMap { Int($0.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") }
    if jobPID != Int(getpid()) {
      launchctl(["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
    }
  }

  @discardableResult
  private func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
  }

  private func launchctlOutput(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
  }

  private func notify(title: String, text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
