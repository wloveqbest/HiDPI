//
//  hidpi — 开源的 macOS HiDPI 工具（命令行）
//
//  机制参考 BetterDummy OpenSource Edition (MIT, Copyright (c) 2021 Istvan T.)
//  详见 README.md 与 LICENSE。
//

import Cocoa
import Foundation
import HDShim
import HiDPICore

// MARK: - 输出辅助

func err(_ message: String) {
  FileHandle.standardError.write(("错误: " + message + "\n").data(using: .utf8)!)
}

func pad(_ text: String, _ width: Int) -> String {
  let count = text.count
  return count >= width ? text : text + String(repeating: " ", count: width - count)
}

let usage = """
hidpi — 开源的 macOS HiDPI 工具

用法:
  hidpi list                             列出显示器及逻辑/像素尺寸
  hidpi modes <displayID>                列出某显示器的全部模式
  hidpi set <displayID> <index>          切换到指定模式索引
  hidpi cycle <displayID> [秒数]          软件断开/重连显示器（会黑屏，激活 override 用）
  hidpi info <displayID>                 显示厂商号/型号号（生成 override 用）
  hidpi state                            显示合盖状态与防睡眠状态
  hidpi profiles                         列出可用的颜色描述文件
  hidpi profile <id> [路径|default]      查看/应用颜色描述文件
  hidpi version                          版本信息
  hidpi help                             显示本帮助

"""

// MARK: - 显示器枚举

struct ScreenInfo {
  let id: CGDirectDisplayID
  let name: String
  let points: (Int, Int)
  let pixels: (Int, Int)
  let isMain: Bool
  let isBuiltin: Bool
}

func screenInfos() -> [ScreenInfo] {
  var infos: [ScreenInfo] = []
  for screen in NSScreen.screens {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
      continue
    }
    let id = CGDirectDisplayID(number.uint32Value)
    var points = (Int(screen.frame.width), Int(screen.frame.height))
    var pixels = points
    if let mode = CGDisplayCopyDisplayMode(id) {
      points = (mode.width, mode.height)
      pixels = (mode.pixelWidth, mode.pixelHeight)
    }
    infos.append(
      ScreenInfo(
        id: id,
        name: screen.localizedName,
        points: points,
        pixels: pixels,
        isMain: CGDisplayIsMain(id) != 0,
        isBuiltin: CGDisplayIsBuiltin(id) != 0
      )
    )
  }
  return infos
}

func cmdList() {
  let infos = screenInfos()
  if infos.isEmpty {
    err("没有检测到显示器")
    return
  }
  print("在线显示器（\(infos.count) 块）\n")
  print(pad("ID", 10) + pad("名称", 30) + pad("逻辑", 14) + pad("像素", 14) + "标记")
  for info in infos {
    let flags = [info.isMain ? "主屏" : nil, info.isBuiltin ? "内建" : nil]
      .compactMap { $0 }.joined(separator: ",")
    print(
      pad(String(info.id), 10)
        + pad(info.name, 30)
        + pad("\(info.points.0)x\(info.points.1)", 14)
        + pad("\(info.pixels.0)x\(info.pixels.1)", 14)
        + flags
    )
  }
}

// MARK: - 模式枚举

func parseUInt32(_ text: String) -> UInt32? {
  if let value = UInt32(text) {
    return value
  }
  let lowered = text.lowercased()
  if lowered.hasPrefix("0x"), let value = UInt32(lowered.dropFirst(2), radix: 16) {
    return value
  }
  return nil
}

func cmdModes(_ args: [String]) {
  guard args.count >= 1, let displayID = parseUInt32(args[0]) else {
    err("用法: hidpi modes <displayID>")
    return
  }
  let modes = DisplayCatalog.rawModes(displayID: displayID)
  guard !modes.isEmpty else {
    err("显示器 \(displayID) 没有返回任何模式")
    return
  }
  let current = DisplayCatalog.current(displayID: displayID)
  print("显示器 \(displayID) 共 \(modes.count) 个模式，当前 \(DisplayCatalog.describe(current))\n")
  print(pad("索引", 8) + pad("逻辑", 12) + pad("实际像素", 14) + pad("刷新", 8) + "类型")
  for mode in modes {
    let currentMark = mode.densityKey == current?.densityKey ? "  ← 当前" : ""
    let kind = mode.hiDPI ? "HiDPI" : "LoDPI"
    print(
      pad(String(mode.index), 8)
        + pad("\(mode.width)x\(mode.height)", 12)
        + pad("\(mode.pixelWidth)x\(mode.pixelHeight)", 14)
        + pad(String(format: "%.0f", mode.refresh), 8)
        + kind + currentMark
    )
  }
}

func cmdSet(_ args: [String]) {
  guard args.count >= 2,
        let displayID = parseUInt32(args[0]),
        let index = Int32(args[1]) else {
    err("用法: hidpi set <displayID> <index>")
    return
  }
  if hd_display_set_mode(displayID, index) != 0 {
    err("切换模式失败（索引越界或系统拒绝）")
    return
  }
  print("已将显示器 \(displayID) 切换到模式索引 \(index)")
}

// MARK: - 额外命令

func cmdInfo(_ args: [String]) {
  guard args.count >= 1, let displayID = parseUInt32(args[0]) else {
    err("用法: hidpi info <displayID>")
    return
  }
  let vendor = hd_display_vendor_id(displayID)
  let product = hd_display_product_id(displayID)
  print("显示器 \(displayID)")
  print("  厂商号   0x\(String(vendor, radix: 16)) (\(vendor))")
  print("  型号号   0x\(String(product, radix: 16)) (\(product))")
  print("  Override 路径  /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(vendor)/DisplayProductID-\(product)")
}

func cmdState() {
  let clamshell = hd_clamshell_closed()
  let label = clamshell == 1 ? "已合盖" : (clamshell == 0 ? "未合盖" : "未知")
  print("合盖状态: \(label)")
  print("提示: 防睡眠开关由菜单栏 App 持有，CLI 无法查询")
}

func cmdProfiles() {
  var paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
  var count: Int32 = 0
  guard hd_list_color_profiles(&paths, &count) == 0, let paths else {
    err("无法枚举颜色描述文件")
    return
  }
  defer { hd_free_profiles(paths, count) }
  print("可用颜色描述文件（\(count) 个）\n")
  for index in 0 ..< Int(count) {
    if let cString = paths[index] {
      print("  " + String(cString: cString))
    }
  }
}

func cmdProfile(_ args: [String]) {
  guard args.count >= 1, let displayID = parseUInt32(args[0]) else {
    err("用法: hidpi profile <displayID> [路径|default]")
    return
  }
  if args.count == 1 {
    if let current = hd_current_color_profile(displayID) {
      defer { free(current) }
      print("显示器 \(displayID) 当前描述文件: \(String(cString: current))")
    } else {
      print("显示器 \(displayID) 使用系统默认描述文件")
    }
    return
  }

  let target = args[1]
  let path: String? = target.lowercased() == "default" ? nil : target
  if let path, !FileManager.default.fileExists(atPath: path) {
    err("找不到文件: \(path)")
    return
  }
  let result = path.map { hd_apply_color_profile(displayID, $0) } ?? hd_apply_color_profile(displayID, nil)
  if result != 0 {
    err("应用颜色描述文件失败，错误码 \(result)")
    return
  }
  print(path == nil ? "已恢复系统默认颜色描述文件" : "已应用 \(path!)")
}

func screenCount() -> Int {
  var count: UInt32 = 0
  CGGetActiveDisplayList(0, nil, &count)
  return Int(count)
}

func cmdCycle(_ args: [String]) {
  guard args.count >= 1, let displayID = parseUInt32(args[0]) else {
    err("用法: hidpi cycle <displayID> [秒数]")
    return
  }
  let seconds = args.count >= 2 ? (Double(args[1]) ?? 2) : 2
  print("断开显示器 \(displayID) \(Int(seconds)) 秒后重连（屏幕会黑一下）…")
  let result = hd_cycle_display(displayID, seconds)
  switch result {
  case 0:
    print("已完成断开/重连")
  case -1:
    err("CGSConfigureDisplayEnabled 不可用")
  case -2:
    err("系统拒绝了断开操作")
  case -3, -4:
    err("重连步骤失败，请立刻执行: hidpi cycle \(displayID) 0 或重新连接线缆")
  default:
    err("未知错误 \(result)")
  }
}

// MARK: - 入口

// 让输出在重定向到文件/管道时也能实时可见
setvbuf(stdout, nil, _IONBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
  print(usage)
  exit(1)
}

switch arguments[0] {
case "list", "ls":
  cmdList()
case "modes":
  cmdModes(Array(arguments.dropFirst()))
case "set":
  cmdSet(Array(arguments.dropFirst()))
case "info":
  cmdInfo(Array(arguments.dropFirst()))
case "state":
  cmdState()
case "profiles":
  cmdProfiles()
case "profile":
  cmdProfile(Array(arguments.dropFirst()))
case "cycle":
  cmdCycle(Array(arguments.dropFirst()))
case "version", "--version", "-v":
  print("hidpi \(hidpiVersion) — MIT License")
  print("虚拟屏机制参考 BetterDummy OpenSource Edition (MIT, Istvan T.)")
case "help", "--help", "-h":
  print(usage)
default:
  err("未知命令: \(arguments[0])")
  print(usage)
  exit(1)
}
