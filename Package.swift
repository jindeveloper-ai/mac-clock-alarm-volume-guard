// swift-tools-version: 6.0

import Foundation
import PackageDescription

let commandLineToolsDeveloperLibrary = "/Library/Developer/CommandLineTools/Library/Developer"
let commandLineToolsFrameworks = "\(commandLineToolsDeveloperLibrary)/Frameworks"
let needsCommandLineToolsTestingPath = FileManager.default.fileExists(
  atPath: "\(commandLineToolsFrameworks)/Testing.framework"
)
let testSwiftSettings: [SwiftSetting] =
  needsCommandLineToolsTestingPath
  ? [.unsafeFlags(["-F", commandLineToolsFrameworks])]
  : []
let testLinkerSettings: [LinkerSetting] =
  needsCommandLineToolsTestingPath
  ? [
    .unsafeFlags([
      "-F", commandLineToolsFrameworks,
      "-Xlinker", "-rpath",
      "-Xlinker", commandLineToolsFrameworks,
      "-Xlinker", "-rpath",
      "-Xlinker", "\(commandLineToolsDeveloperLibrary)/usr/lib",
    ])
  ]
  : []

let package = Package(
  name: "ClockAlarmVolumeGuard",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(
      name: "clock-alarm-volume-guard",
      targets: ["ClockAlarmVolumeGuard"]
    )
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite",
      path: "Sources/CSQLite"
    ),
    .executableTarget(
      name: "ClockAlarmVolumeGuard",
      dependencies: ["CSQLite"]
    ),
    .testTarget(
      name: "ClockAlarmVolumeGuardTests",
      dependencies: ["ClockAlarmVolumeGuard", "CSQLite"],
      swiftSettings: testSwiftSettings,
      linkerSettings: testLinkerSettings
    ),
  ],
  swiftLanguageModes: [.v5]
)
