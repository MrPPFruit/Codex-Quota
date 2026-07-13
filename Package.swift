// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexQuota",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "CodexUsageAccessory", targets: ["CodexUsageAccessory"]),
    ],
    targets: [
        .target(name: "CodexUsageCore"),
        .target(name: "CodexUsageUI", dependencies: ["CodexUsageCore"]),
        .executableTarget(name: "CodexUsageAccessory", dependencies: ["CodexUsageCore", "CodexUsageUI"]),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"]),
        .testTarget(name: "CodexUsageUITests", dependencies: ["CodexUsageCore", "CodexUsageUI"]),
        .testTarget(name: "CodexUsageAccessoryTests", dependencies: ["CodexUsageCore", "CodexUsageUI", "CodexUsageAccessory"]),
    ]
)
