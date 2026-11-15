//
//  ColorProfile.swift — 颜色描述文件的共享封装
//
//  CLI 和菜单栏 App 之前各自调用 shim 并各自去掉 .icc 后缀，
//  这里统一：过滤、命名、应用、查询当前值。
//

import CoreGraphics
import Foundation
import HDShim

public struct ColorProfile: Equatable, Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }

  /// 菜单/列表里显示的名字（去掉 .icc / .icm）
  public var displayName: String {
    let fileName = (path as NSString).lastPathComponent
    let ext = (fileName as NSString).pathExtension.lowercased()
    guard ext == "icc" || ext == "icm" else { return fileName }
    return (fileName as NSString).deletingPathExtension
  }
}

public enum ColorProfileCatalog {
  /// 可用于显示器的 profile（shim 内已按 ICC 头过滤 mntr + RGB）
  public static func all() -> [ColorProfile] {
    var paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    var count: Int32 = 0
    guard hd_list_color_profiles(&paths, &count) == 0, let paths else {
      return []
    }
    defer { hd_free_profiles(paths, count) }

    var profiles: [ColorProfile] = []
    profiles.reserveCapacity(Int(count))
    for index in 0 ..< Int(count) {
      guard let cString = paths[index] else { continue }
      profiles.append(ColorProfile(path: String(cString: cString)))
    }
    return profiles
  }

  /// 当前生效的自定义 profile 路径；nil 表示系统默认
  public static func current(displayID: CGDirectDisplayID) -> String? {
    guard let pointer = hd_current_color_profile(displayID) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
  }

  /// 应用 profile；path 为 nil 表示回到系统默认。返回 0 表示成功
  @discardableResult
  public static func apply(displayID: CGDirectDisplayID, path: String?) -> Int32 {
    if let path {
      return hd_apply_color_profile(displayID, path)
    }
    return hd_apply_color_profile(displayID, nil)
  }
}
