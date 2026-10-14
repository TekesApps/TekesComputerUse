// swift-tools-version: 6.1

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
  name: "TekesComputerUse",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "TekesComputerUsePermissionUI", targets: ["TekesComputerUsePermissionUI"]),
    .executable(name: "TekesComputerUseHelper", targets: ["TekesComputerUseHelper"])
  ],
  targets: [
    .target(name: "TekesComputerUsePermissionUI"),
    .executableTarget(
      name: "TekesComputerUseHelper",
      dependencies: ["TekesComputerUsePermissionUI"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("ScreenCaptureKit"),
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", "\(packageRoot)/Resources/Info.plist",
        ]),
      ]),
    .testTarget(name: "TekesComputerUseHelperTests", dependencies: ["TekesComputerUseHelper"]),
  ])
