//
//  AppDelegate.swift — 状态、生命周期与副作用
//
//  菜单长什么样由 MenuBuilder 决定；这里只负责：
//  维护状态（防睡眠、自启动、颜色持久化）、响应动作、处理唤醒/换屏。
//

import Cocoa
import Foundation
import HDShim
import HiDPICore

private let kSleepPreventionKey = "preventDisplaySleep"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private var menuRouter: MenuActionRouter?

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
    menu.autoenablesItems = false
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

    if ProcessInfo.processInfo.environment["HIDPI_DUMP_MENU"] == "1" {
      dump(menu: menu, depth: 0)
      exit(0)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    _ = hd_prevent_sleep(0)
  }

  /// 只在打开前构建一次；悬停子菜单时不重建，避免跳动
  func menuWillOpen(_ menu: NSMenu) {
    rebuildMenu()
  }

  // MARK: - 菜单

  private func rebuildMenu() {
    guard let menu = statusItem.menu else { return }
    menu.removeAllItems()

    let router = MenuActionRouter()
    menuRouter = router

    let displays = DisplayCatalog.attachedDisplays().map { display -> MenuDisplay in
      let current = DisplayCatalog.current(displayID: display.id)
      return MenuDisplay(
        id: display.id,
        name: display.name,
        modeText: DisplayCatalog.describe(current),
        refresh: current.map { Int($0.refresh.rounded()) } ?? 0
      )
    }

    let state = MenuState(
      displays: displays,
      clamshellText: DisplayCatalog.clamshellText(),
      sleepPreventionOn: hd_sleep_prevented() == 1,
      launchAtLoginOn: LaunchAtLogin.isEnabled()
    )

    let items = MenuBuilder.build(
      state: state,
      router: router,
      onSelectMode: { [weak self] displayID, index in
        self?.selectMode(displayID: displayID, index: index)
      },
      onToggleHiDPI: { [weak self] displayID in
        self?.toggleHiDPI(displayID: displayID)
      },
      onApplyProfile: { [weak self] displayID, path in
        self?.applyProfile(displayID: displayID, path: path)
      },
      onToggleHDR: { [weak self] displayID in
        self?.toggleHDR(displayID: displayID)
      },
      onToggleSleepPrevention: { [weak self] in
        self?.toggleSleepPrevention()
      },
      onToggleLaunchAtLogin: { [weak self] in
        self?.toggleLaunchAtLogin()
      }
    )

    for item in items {
      menu.addItem(item)
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
      if let sub = item.submenu { dump(menu: sub, depth: depth + 1) }
    }
  }

  // MARK: - 动作

  private func selectMode(displayID: CGDirectDisplayID, index: Int) {
    if hd_display_set_mode(displayID, Int32(index)) != 0 {
      notify(title: "切换失败", text: "系统拒绝了这次模式切换。")
    }
  }

  private func toggleHiDPI(displayID: CGDirectDisplayID) {
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
  }

  private func applyProfile(displayID: CGDirectDisplayID, path: String?) {
    let result = path.map { hd_apply_color_profile(displayID, $0) }
      ?? hd_apply_color_profile(displayID, nil)
    if result != 0 {
      let reason: String
      switch result {
      case -5: reason = "该文件不是显示器类 RGB profile，系统会直接拒绝。"
      case -2: reason = "ColorSync 拒绝了该描述文件。"
      case -1: reason = "无法获取显示器标识。"
      default: reason = "错误码 \(result)"
      }
      notify(title: "应用失败", text: reason)
      return
    }
    UserDefaults.standard.set(path ?? "", forKey: "profile-\(displayID)")
  }

  private func toggleHDR(displayID: CGDirectDisplayID) {
    let current = hd_hdr_enabled(displayID)
    let result = hd_hdr_set(displayID, current == 1 ? 0 : 1)
    switch result {
    case 0:
      break
    case -2:
      notify(title: "不支持 HDR", text: "当前 HDMI 链路或分辨率不支持 HDR。")
    default:
      notify(title: "切换失败", text: "错误码 \(result)")
    }
  }

  private func toggleSleepPrevention() {
    let enabled = !UserDefaults.standard.bool(forKey: kSleepPreventionKey)
    UserDefaults.standard.set(enabled, forKey: kSleepPreventionKey)
    if hd_prevent_sleep(enabled ? 1 : 0) != 0 {
      UserDefaults.standard.set(false, forKey: kSleepPreventionKey)
      notify(title: "设置失败", text: "无法创建防睡眠断言。")
    }
  }

  // MARK: - 唤醒 / 屏幕变化

  @objc private func didWake() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      self?.restoreColorProfile()
    }
  }

  private func restoreColorProfile() {
    let defaults = UserDefaults.standard
    for display in DisplayCatalog.attachedDisplays() {
      guard let profile = defaults.string(forKey: "profile-\(display.id)"), !profile.isEmpty else { continue }

      var currentPointer = hd_current_color_profile(display.id)
      let current = currentPointer.map { String(cString: $0) }
      if let currentPointer { free(currentPointer) }
      guard current != profile else { continue }

      _ = hd_apply_color_profile(display.id, profile)
    }
  }

  private func toggleLaunchAtLogin() {
    LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled())
  }

  private func notify(title: String, text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
