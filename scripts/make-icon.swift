// 生成 App 图标（1024×1024 PNG），供 iconutil 打包成 .icns
// 用法: swift scripts/make-icon.swift <输出路径.png>

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let side: CGFloat = 1024

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

// 背景：圆角矩形 + 对角渐变
let bounds = NSRect(x: 0, y: 0, width: side, height: side)
let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 64, dy: 64), xRadius: 208, yRadius: 208)
let gradient = NSGradient(colors: [
  NSColor(srgbRed: 0.24, green: 0.30, blue: 0.86, alpha: 1.0),
  NSColor(srgbRed: 0.48, green: 0.20, blue: 0.78, alpha: 1.0),
])!
gradient.draw(in: plate, angle: -60)

// 屏幕边框
let screen = NSBezierPath(roundedRect: NSRect(x: 208, y: 300, width: 608, height: 392), xRadius: 40, yRadius: 40)
NSColor(white: 1.0, alpha: 0.92).setStroke()
screen.lineWidth = 26
screen.stroke()

// 屏幕内的 "2x"
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 190, weight: .bold),
  .foregroundColor: NSColor(white: 1.0, alpha: 0.95),
  .paragraphStyle: paragraph,
]
let text = NSAttributedString(string: "2x", attributes: attrs)
let textSize = text.size()
text.draw(at: NSPoint(x: (side - textSize.width) / 2, y: 396))

// 底座
let stand = NSBezierPath(roundedRect: NSRect(x: 452, y: 178, width: 120, height: 96), xRadius: 24, yRadius: 24)
NSColor(white: 1.0, alpha: 0.92).setFill()
stand.fill()
let base = NSBezierPath(roundedRect: NSRect(x: 356, y: 128, width: 312, height: 56), xRadius: 28, yRadius: 28)
base.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write(Data("图标渲染失败\n".utf8))
  exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("已生成 \(outputPath)")
