// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "hidpi",
  platforms: [.macOS(.v12)],
  targets: [
    .target(
      name: "HDShim",
      path: "Sources/HDShim",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("Foundation"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ColorSync"),
      ]
    ),
    .executableTarget(
      name: "hidpi",
      dependencies: ["HDShim"],
      path: "Sources/hidpi"
    ),
    .executableTarget(
      name: "HiDPIMenuBar",
      dependencies: ["HDShim"],
      path: "Sources/HiDPIMenuBar"
    ),
  ]
)
