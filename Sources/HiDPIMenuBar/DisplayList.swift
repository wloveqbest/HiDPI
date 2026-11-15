//
//  DisplayList.swift — NSScreen → 显示器清单（AppKit 只出现在 App 层）
//

import AppKit
import CoreGraphics
import HiDPICore

extension DisplayCatalog {
  /// 当前在线的显示器（NSScreen 顺序，主屏在前）
  static func attachedDisplays() -> [(id: CGDirectDisplayID, name: String)] {
    NSScreen.screens.compactMap { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
      }
      return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
    }
  }
}
