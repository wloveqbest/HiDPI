//
//  MenuBuilder.swift — 菜单呈现层
//
//  只负责"长什么样"：图标、勾选、分组、宽度。
//  不持有状态，也不直接调用显示 API —— 动作通过 MenuActionRouter 的回调交给 AppDelegate。
//

import AppKit
import CoreGraphics
import Foundation
import HDShim
import HiDPICore

/// 菜单里的一个显示器快照
struct MenuDisplay {
  let id: CGDirectDisplayID
  let name: String
  let modeText: String
  let refresh: Int
}

struct MenuState {
  let displays: [MenuDisplay]
  let clamshellText: String
  let sleepPreventionOn: Bool
  let launchAtLoginOn: Bool
}

/// 把闭包挂到 NSMenuItem 上，避免 Action 方法散落在 AppDelegate 里
final class MenuActionRouter: NSObject {
  private var handlers: [() -> Void] = []

  func makeItem(
    title: String,
    systemImage: String? = nil,
    state: NSControl.StateValue = .off,
    indentation: Int = 0,
    action: @escaping () -> Void
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(dispatch(_:)), keyEquivalent: "")
    item.target = self
    item.indentationLevel = indentation
    item.state = state
    if let systemImage, let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) {
      image.isTemplate = true
      item.image = image
    }
    item.representedObject = handlers.count
    handlers.append(action)
    return item
  }

  func makeSubmenu(title: String, systemImage: String?, items: [NSMenuItem]) -> NSMenuItem {
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    submenu.minimumWidth = 280
    for item in items {
      submenu.addItem(item)
    }
    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    parent.submenu = submenu
    if let systemImage, let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) {
      image.isTemplate = true
      parent.image = image
    }
    return parent
  }

  @objc private func dispatch(_ sender: NSMenuItem) {
    guard let index = sender.representedObject as? Int, index < handlers.count else { return }
    handlers[index]()
  }
}

enum MenuBuilder {
  static func build(
    state: MenuState,
    router: MenuActionRouter,
    onSelectMode: @escaping (CGDirectDisplayID, Int) -> Void,
    onToggleHiDPI: @escaping (CGDirectDisplayID) -> Void,
    onApplyProfile: @escaping (CGDirectDisplayID, String?) -> Void,
    onToggleSleepPrevention: @escaping () -> Void,
    onToggleLaunchAtLogin: @escaping () -> Void
  ) -> [NSMenuItem] {
    var items: [NSMenuItem] = []

    items.append(header(state: state))
    items.append(.separator())

    let single = state.displays.count == 1

    if single, let display = state.displays.first {
      items.append(contentsOf: displayItems(
        for: display, router: router,
        onSelectMode: onSelectMode, onToggleHiDPI: onToggleHiDPI, onApplyProfile: onApplyProfile
      ))
    } else if !state.displays.isEmpty {
      let children = state.displays.map { display -> NSMenuItem in
        let inner = displayItems(
          for: display, router: router,
          onSelectMode: onSelectMode, onToggleHiDPI: onToggleHiDPI, onApplyProfile: onApplyProfile
        )
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.minimumWidth = 280
        for item in inner { submenu.addItem(item) }
        let parent = NSMenuItem(
          title: "\(display.name) — \(display.modeText) · \(display.refresh)Hz",
          action: nil, keyEquivalent: ""
        )
        parent.submenu = submenu
        return parent
      }
      items.append(router.makeSubmenu(
        title: "显示器（\(state.displays.count)）", systemImage: "display", items: children
      ))
    } else {
      let none = router.makeItem(title: "没有检测到显示器", systemImage: "exclamationmark.triangle") {}
      none.isEnabled = false
      items.append(none)
    }

    items.append(.separator())

    items.append(router.makeItem(
      title: "保持屏幕常亮", systemImage: "sun.max",
      state: state.sleepPreventionOn ? .on : .off
    ) { onToggleSleepPrevention() })
    items.append(router.makeItem(
      title: "开机自启动", systemImage: "power",
      state: state.launchAtLoginOn ? .on : .off
    ) { onToggleLaunchAtLogin() })

    items.append(.separator())
    items.append(router.makeItem(
      title: "退出 HiDPI", systemImage: "rectangle.portrait.and.arrow.right"
    ) {})

    return items
  }

  // MARK: - 头部

  private static func header(state: MenuState) -> NSMenuItem {
    let text: String
    if let first = state.displays.first {
      let name = state.displays.count == 1 ? first.name : "\(state.displays.count) 块显示器"
      text = "\(name) · \(first.modeText) · \(first.refresh)Hz\(state.clamshellText)"
    } else {
      text = "没有检测到显示器"
    }
    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    return item
  }

  // MARK: - 单块显示器的操作项

  private static func displayItems(
    for display: MenuDisplay,
    router: MenuActionRouter,
    onSelectMode: @escaping (CGDirectDisplayID, Int) -> Void,
    onToggleHiDPI: @escaping (CGDirectDisplayID) -> Void,
    onApplyProfile: @escaping (CGDirectDisplayID, String?) -> Void
  ) -> [NSMenuItem] {
    let entries = DisplayCatalog.deduped(displayID: display.id)
    guard !entries.isEmpty else {
      let item = router.makeItem(title: "无法读取模式表", systemImage: "exclamationmark.triangle") {}
      item.isEnabled = false
      return [item]
    }

    let native = DisplayCatalog.nativePixelSize(displayID: display.id)
    let current = DisplayCatalog.current(displayID: display.id)
    let common = DisplayCatalog.commonModes(displayID: display.id)

    // 分辨率
    var resolutionItems: [NSMenuItem] = []
    var seen = Set<String>()
    for entry in common {
      if seen.contains(entry.sizeKey) { continue }
      seen.insert(entry.sizeKey)

      let wantHiDPI = current?.hiDPI ?? true
      let sameRate = common.first {
        $0.width == entry.width && $0.height == entry.height
          && $0.hiDPI == wantHiDPI && Int($0.refresh.rounded()) == Int((current?.refresh ?? 0).rounded())
      }
      let variant = sameRate
        ?? common.first {
          $0.width == entry.width && $0.height == entry.height && $0.hiDPI == wantHiDPI
        }
        ?? entry

      let hasHiDPI = DisplayCatalog.hasHiDPIVariant(
        width: entry.width, height: entry.height, displayID: display.id)
      var title = "\(entry.width)×\(entry.height)"
      if !hasHiDPI {
        let isNative = entry.width == native.width && entry.height == native.height
        title += isNative ? "  原生" : "  无 HiDPI"
      }

      let isCurrent = entry.width == current?.width && entry.height == current?.height
      let item = router.makeItem(
        title: title,
        state: isCurrent ? .on : .off
      ) { onSelectMode(display.id, variant.index) }
      resolutionItems.append(item)
    }

    // 刷新率
    var refreshItems: [NSMenuItem] = []
    if let current {
      let candidates = DisplayCatalog.rawModes(displayID: display.id).filter {
        $0.width == current.width && $0.height == current.height && $0.hiDPI == current.hiDPI
      }
      for rate in Set(candidates.map { Int($0.refresh.rounded()) }).sorted() {
        guard let match = candidates.first(where: { Int($0.refresh.rounded()) == rate }) else { continue }
        let item = router.makeItem(
          title: "\(rate) Hz",
          state: rate == Int(current.refresh.rounded()) ? .on : .off
        ) { onSelectMode(display.id, match.index) }
        refreshItems.append(item)
      }
    }
    if refreshItems.isEmpty {
      let item = router.makeItem(title: "只有一个刷新率") {}
      item.isEnabled = false
      refreshItems.append(item)
    }

    // 颜色描述文件
    var profileItems: [NSMenuItem] = []
    let currentProfile = ColorProfileCatalog.current(displayID: display.id)

    profileItems.append(router.makeItem(
      title: "系统默认",
      state: currentProfile == nil ? .on : .off
    ) { onApplyProfile(display.id, nil) })

    profileItems.append(.separator())

    for profile in ColorProfileCatalog.all() {
      profileItems.append(router.makeItem(
        title: profile.displayName,
        state: profile.path == currentProfile ? .on : .off
      ) { onApplyProfile(display.id, profile.path) })
    }

    let hidpiItem = router.makeItem(
      title: "启用 HiDPI",
      systemImage: "sparkles",
      state: current?.hiDPI == true ? .on : .off
    ) { onToggleHiDPI(display.id) }

    return [
      router.makeSubmenu(title: "分辨率", systemImage: "aspectratio", items: resolutionItems),
      router.makeSubmenu(title: "刷新率", systemImage: "arrow.triangle.2.circlepath", items: refreshItems),
      hidpiItem,
      router.makeSubmenu(title: "颜色描述文件", systemImage: "paintpalette", items: profileItems),
    ]
  }
}
