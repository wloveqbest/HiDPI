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
  hidpi create [选项]                    创建 HiDPI 虚拟显示器并保持连接
      --size <WxH>       逻辑分辨率（默认 1920x1080）
      --refresh <HZ>     刷新率（默认 60）
      --name <NAME>      显示器名称（默认 HiDPI Display）
      --lo               创建 1x（非 HiDPI）显示
      --seconds <N>      运行 N 秒后自动断开（默认运行到 Ctrl-C）
  hidpi detect                           让系统重新枚举显示器
  hidpi cycle <displayID> [秒数]          软件断开/重连显示器（会黑屏，激活 override 用）
  hidpi activate <displayID>             激活 override（等同 cycle <id> 2）
  hidpi info <displayID>                 显示厂商号/型号号（生成 override 用）
  hidpi state                            显示合盖状态与防睡眠状态
  hidpi profiles                         列出可用的颜色描述文件
  hidpi profile <id> [路径|default]      查看/应用颜色描述文件
  hidpi version                          版本信息
  hidpi help                             显示本帮助

说明: 虚拟显示器与进程同寿命，进程退出即断开。
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
  let virtualCount = hd_virtual_display_count()
  if virtualCount > 0 {
    print("\n本进程创建的虚拟显示器: \(virtualCount) 块")
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

func cmdDetect() {
  if hd_detect_displays() != 0 {
    err("无法调用 SLSDetectDisplays（该 macOS 版本未导出此符号）")
    return
  }
  print("已请求系统重新枚举显示器")
}

/// 执行外部命令，返回退出码
@discardableResult
func run(_ path: String, _ arguments: [String]) -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  do {
    try process.run()
  } catch {
    return -1
  }
  process.waitUntilExit()
  return process.terminationStatus
}

func cmdActivate(_ args: [String]) {
  guard let displayID = args.first.flatMap(parseUInt32) else {
    err("用法: hidpi activate <displayID>   （等价于 hidpi cycle <id> 2）")
    return
  }
  print("断开并重连显示器 \(displayID)，迫使系统重读 override（屏幕会黑一下）…")
  let result = hd_cycle_display(displayID, 2.0)
  if result == 0 {
    print("已激活")
  } else {
    err("激活失败，错误码 \(result)")
  }
}

/// 用公开 API 数一数当前在线显示器
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

// MARK: - 创建虚拟显示器

func cmdCreate(_ args: [String]) {
  var logicalWidth = 1920
  var logicalHeight = 1080
  var refresh: Double = 60
  var name = "HiDPI Display"
  var hiDPI = true
  var seconds: Double?

  var i = 0
  while i < args.count {
    switch args[i] {
    case "--size":
      i += 1
      guard i < args.count else { err("--size 需要一个参数"); return }
      let parts = args[i].lowercased().split(separator: "x")
      guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w >= 320, h >= 240 else {
        err("--size 格式应为 WxH，例如 1920x1080")
        return
      }
      logicalWidth = w
      logicalHeight = h
    case "--refresh":
      i += 1
      guard i < args.count, let value = Double(args[i]), value > 0 else {
        err("--refresh 需要一个正数")
        return
      }
      refresh = value
    case "--name":
      i += 1
      guard i < args.count else { err("--name 需要一个参数"); return }
      name = args[i]
    case "--lo":
      hiDPI = false
    case "--seconds":
      i += 1
      guard i < args.count, let value = Double(args[i]), value > 0 else {
        err("--seconds 需要一个正数")
        return
      }
      seconds = value
    default:
      err("未知选项: \(args[i])")
      print(usage)
      return
    }
    i += 1
  }

  let displayID = hd_create_virtual_display(
    UInt32(logicalWidth),
    UInt32(logicalHeight),
    refresh,
    name,
    hiDPI ? 1 : 0
  )
  guard displayID != 0 else {
    err("创建虚拟显示器失败")
    err("常见原因: 进程跑在 Rosetta 下、系统禁用了 CGVirtualDisplay、或分辨率过大。")
    return
  }

  let scale = hiDPI ? 2 : 1
  print("已创建虚拟显示器")
  print("  ID        \(displayID)")
  print("  名称      \(name)")
  print("  逻辑      \(logicalWidth)x\(logicalHeight) pt")
  print("  背衬      \(logicalWidth * scale)x\(logicalHeight * scale) px（\(hiDPI ? "HiDPI 2x" : "LoDPI 1x")）")
  print("  刷新率    \(Int(refresh)) Hz")
  print("\n下一步:")
  print("  hidpi modes \(displayID)                 查看可用模式")
  print("  hidpi set \(displayID) <索引>            切换模式")
  print("  系统设置 > 显示器 > 为该虚拟屏选择 HiDPI 档位")

  let createdID = UInt32(displayID)
  let hidpiModes = DisplayCatalog.rawModes(displayID: createdID)
    .filter { $0.hiDPI }
    .map { "\($0.width)x\($0.height)" }
  if hidpiModes.isEmpty {
    print("\n注意: 该虚拟屏没有暴露 HiDPI 模式")
  } else {
    let unique = Array(Set(hidpiModes)).sorted()
    print("\n已确认 HiDPI 模式: " + unique.joined(separator: ", "))
  }

  if let seconds {
    print("\n\(Int(seconds)) 秒后自动断开…")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
      hd_release_virtual_displays()
      print("已断开虚拟显示器")
      exit(0)
    }
  } else {
    print("\n按 Ctrl-C 断开并退出。")
  }

  // 虚拟显示器与进程同寿命，保持主线程存活
  signal(SIGINT, SIG_IGN)
  signal(SIGTERM, SIG_IGN)
  let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
      hd_release_virtual_displays()
      print("\n已断开虚拟显示器")
      exit(0)
    }
    source.resume()
    return source
  }
  withExtendedLifetime(sources) {
    RunLoop.main.run()
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
case "create":
  cmdCreate(Array(arguments.dropFirst()))
case "info":
  cmdInfo(Array(arguments.dropFirst()))
case "state":
  cmdState()
case "profiles":
  cmdProfiles()
case "profile":
  cmdProfile(Array(arguments.dropFirst()))
case "detect":
  cmdDetect()
case "cycle":
  cmdCycle(Array(arguments.dropFirst()))
case "activate":
  cmdActivate(Array(arguments.dropFirst()))
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
