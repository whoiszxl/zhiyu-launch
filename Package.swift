// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZhiyuLaunch",
    platforms: [
        .macOS("27.0")
    ],
    targets: [
        // All application logic lives in a library so it can be unit-tested.
        .target(
            name: "ZhiyuLaunchKit"
        ),
        // Thin executable wrapper that owns the NSApplication lifecycle.
        .executableTarget(
            name: "ZhiyuLaunch",
            dependencies: ["ZhiyuLaunchKit"]
        ),
        .testTarget(
            name: "ZhiyuLaunchKitTests",
            dependencies: ["ZhiyuLaunchKit"]
        ),
    ]
)
