// swift-tools-version: 6.0
import PackageDescription

// SwiftPM records the deployment target (14.0) as the SDK version in LC_BUILD_VERSION, and the system frameworks
// read that field for "linked on or after" behaviour: AppKit draws the old design (no Liquid Glass) and AVFoundation
// hands back HDR frames ~3x too bright (wrong HDR covers). Every binary records the real SDK instead; raise this
// with Xcode's SDK (`xcrun --sdk macosx --show-sdk-version`).
let sdkVersion = "27.0"
let realSDK: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", sdkVersion])]

let package = Package(
    name: "LiveWall",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiveWallCore", targets: ["LiveWallCore"]),
        .executable(name: "livewall-cli", targets: ["livewall-cli"]),
        .executable(name: "LiveWall", targets: ["LiveWall"]),
    ],
    targets: [
        .target(
            name: "LiveWallCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "livewall-cli",
            dependencies: ["LiveWallCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: realSDK
        ),
        // SwiftUI bits the app uses (glass fallbacks, the bare video view)
        .target(
            name: "SharedUI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LiveWall",
            dependencies: ["LiveWallCore", "SharedUI"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AVKit")] + realSDK       // SwiftUI's VideoPlayer needs AVKit loaded at launch
        ),
        .testTarget(
            name: "LiveWallCoreTests",
            dependencies: ["LiveWallCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]      // the host (xctest) already records the real SDK
        ),
    ]
)
