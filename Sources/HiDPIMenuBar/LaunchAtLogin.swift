//
//  LaunchAtLogin.swift — 开机自启动（LaunchAgent）
//

import Foundation

enum LaunchAtLogin {
  static let label = "pro.local.hidpi"

  static var agentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(label).plist")
  }

  static func isEnabled() -> Bool {
    FileManager.default.fileExists(atPath: agentURL.path)
  }

  static func setEnabled(_ enabled: Bool) {
    if enabled {
      install()
    } else {
      uninstall()
    }
  }

  private static func install() {
    guard let executable = Bundle.main.executablePath else { return }
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(label)</string>
      <key>ProgramArguments</key><array><string>\(executable)</string></array>
      <key>RunAtLoad</key><true/>
      <key>LimitLoadToSessionType</key><string>Aqua</string>
      <key>ProcessType</key><string>Interactive</string>
    </dict>
    </plist>
    """
    try? FileManager.default.createDirectory(
      at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? plist.write(to: agentURL, atomically: true, encoding: .utf8)
    launchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
  }

  private static func uninstall() {
    try? FileManager.default.removeItem(at: agentURL)

    // 当前进程若不是由该 job 启动，才卸载，避免把自己杀掉
    let output = launchctlOutput(["print", "gui/\(getuid())/\(label)"]) ?? ""
    let pidLine = output.split(separator: "\n").first { $0.contains("pid = ") }
    let jobPID = pidLine.flatMap { Int($0.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") }
    if jobPID != Int(getpid()) {
      launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }
  }

  @discardableResult
  private static func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
  }

  private static func launchctlOutput(_ arguments: [String]) -> String? {
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
}
