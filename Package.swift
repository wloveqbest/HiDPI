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
    .target(
      name: "HiDPICore",
      dependencies: ["HDShim"],
      path: "Sources/HiDPICore"
    ),
    .executableTarget(
      name: "hidpi",
      dependencies: ["HDShim", "HiDPICore"],
      path: "Sources/hidpi"
    ),
    .executableTarget(
      name: "HiDPIMenuBar",
      dependencies: ["HDShim", "HiDPICore"],
      path: "Sources/HiDPIMenuBar"
    ),
  ]
)
