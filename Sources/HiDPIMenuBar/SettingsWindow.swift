//
//  SettingsWindow.swift — 设置窗口（颜色描述文件）
//

import Cocoa
import Foundation
import HDShim
import HiDPICore

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
    window.hidesOnDeactivate = false
    window.setContentSize(NSSize(width: 380, height: 130))
    window.contentMinSize = NSSize(width: 380, height: 130)
    window.contentMaxSize = NSSize(width: 380, height: 130)
    window.isMovableByWindowBackground = true
    super.init(window: window)
    window.delegate = self
    buildUI()
  }

  required init?(coder: NSCoder) { fatalError() }

  func windowWillClose(_ notification: Notification) {
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
    let displays = DisplayCatalog.attachedDisplays()
    displayIDs = displays.map(\.id)

    displayPopup.removeAllItems()
    for display in displays {
      displayPopup.addItem(withTitle: display.name)
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
