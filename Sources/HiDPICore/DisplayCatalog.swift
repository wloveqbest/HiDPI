//
//  HiDPICore — CLI 与菜单栏 App 共享的显示模型
//
//  之前两个可执行 target 各自维护一份"模式表去重 / 当前模式 / 原生分辨率"逻辑，
//  这里统一，避免两边行为漂移。
//

import CoreGraphics
import Foundation
import HDShim

public let hidpiVersion = "1.0.0"

/// 模式表里的一条
public struct DisplayModeInfo: Equatable, Sendable {
  public let index: Int
  public let width: UInt32
  public let height: UInt32
  public let hiDPI: Bool
  public let refresh: Double

  public init(index: Int, width: UInt32, height: UInt32, hiDPI: Bool, refresh: Double) {
    self.index = index
    self.width = width
    self.height = height
    self.hiDPI = hiDPI
    self.refresh = refresh
  }

  public var pixelWidth: UInt32 { hiDPI ? width * 2 : width }
  public var pixelHeight: UInt32 { hiDPI ? height * 2 : height }
  public var sizeKey: String { "\(width)x\(height)" }
  public var densityKey: String { "\(width)x\(height)x\(hiDPI ? 1 : 0)" }
}

public enum DisplayCatalog {
  /// 常见分辨率白名单（逻辑尺寸）
  public static let commonSizes: [(width: UInt32, height: UInt32)] = [
    (1280, 800), (1440, 900), (1512, 982), (1600, 900), (1680, 1050),
    (1728, 1117), (1920, 1080), (1920, 1200), (2048, 1152), (2304, 1296),
    (2560, 1440), (2560, 1600), (2880, 1620), (3008, 1692), (3200, 1800),
    (3440, 1440), (3840, 2160),
  ]

  /// 原始模式表（不去重）
  public static func rawModes(displayID: CGDirectDisplayID) -> [DisplayModeInfo] {
    let count = hd_display_mode_count(displayID)
    guard count > 0 else { return [] }
    var modes: [DisplayModeInfo] = []
    modes.reserveCapacity(Int(count))
    for index in 0 ..< Int(count) {
      var mode = hd_mode_t()
      guard hd_display_mode_at(displayID, Int32(index), &mode) == 0 else { continue }
      modes.append(DisplayModeInfo(index: index, width: mode.width, height: mode.height,
                                   hiDPI: mode.hiDPI == 1, refresh: mode.refreshRate))
    }
    return modes
  }

  /// 同一 (宽,高,HiDPI) 只保留最高刷新率，按尺寸升序
  public static func deduped(displayID: CGDirectDisplayID) -> [DisplayModeInfo] {
    var byKey: [String: DisplayModeInfo] = [:]
    for mode in rawModes(displayID: displayID) {
      if let existing = byKey[mode.densityKey], existing.refresh >= mode.refresh { continue }
      byKey[mode.densityKey] = mode
    }
    return byKey.values.sorted { lhs, rhs in
      if lhs.width != rhs.width { return lhs.width < rhs.width }
      if lhs.height != rhs.height { return lhs.height < rhs.height }
      return lhs.hiDPI && !rhs.hiDPI
    }
  }

  /// 当前生效模式（index 为 -1）
  public static func current(displayID: CGDirectDisplayID) -> DisplayModeInfo? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    return DisplayModeInfo(index: -1, width: UInt32(mode.width), height: UInt32(mode.height),
                           hiDPI: mode.pixelWidth == mode.width * 2, refresh: mode.refreshRate)
  }

  /// 面板原生像素尺寸：取最大的 LoDPI 模式（HiDPI 是超采样，会超过面板）
  public static func nativePixelSize(displayID: CGDirectDisplayID) -> (width: UInt32, height: UInt32) {
    var best: (width: UInt32, height: UInt32) = (0, 0)
    for mode in rawModes(displayID: displayID) where !mode.hiDPI {
      if mode.width * mode.height > best.width * best.height {
        best = (mode.width, mode.height)
      }
    }
    return best
  }

  /// 常见尺寸（按尺寸去重，保留每条密度）
  public static func commonModes(displayID: CGDirectDisplayID) -> [DisplayModeInfo] {
    deduped(displayID: displayID).filter { mode in
      commonSizes.contains { $0.width == mode.width && $0.height == mode.height }
    }
  }

  /// 某尺寸是否有 HiDPI 变体
  public static func hasHiDPIVariant(width: UInt32, height: UInt32,
                                     displayID: CGDirectDisplayID) -> Bool {
    rawModes(displayID: displayID).contains {
      $0.width == width && $0.height == height && $0.hiDPI
    }
  }

  /// "1920×1080 HiDPI" 这样的描述
  public static func describe(_ mode: DisplayModeInfo?) -> String {
    guard let mode else { return "未知" }
    return "\(mode.width)×\(mode.height)\(mode.hiDPI ? " HiDPI" : "")"
  }

  /// 合盖状态文案
  public static func clamshellText() -> String {
    switch hd_clamshell_closed() {
    case 1: return " · 已合盖"
    case 0: return " · 开盖"
    default: return ""
    }
  }
}
