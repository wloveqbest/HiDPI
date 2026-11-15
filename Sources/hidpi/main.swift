//
//  main.swift — 参数解析与分发
//

import Foundation
import HiDPICore

private let version = hidpiVersion

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
  print("hidpi \(version) — MIT License")
  print("菜单栏 App + CLI；私有 API 声明参考 BetterDummy OpenSource Edition (MIT, Istvan T.)")
case "help", "--help", "-h":
  print(usage)
default:
  err("未知命令: \(arguments[0])")
  print(usage)
  exit(1)
}
