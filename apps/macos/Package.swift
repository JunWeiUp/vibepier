// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "vibepier",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VibeKit", targets: ["VibeKit"]),
        .executable(name: "vibepier", targets: ["vibepier"]),
        .executable(name: "VibePierApp", targets: ["VibePierApp"]),
    ],
    targets: [
        .target(name: "VibeLocalization"),
        .target(
            name: "VibeKit",
            dependencies: ["VibeLocalization"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "VibePierCore",
            dependencies: ["VibeKit", "VibeLocalization"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(name: "vibepier", dependencies: ["VibePierCore"]),
        .executableTarget(
            name: "VibePierApp",
            dependencies: ["VibePierCore"],
            path: "Sources/VibePierApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibeKitTests",
            dependencies: ["VibeKit"]
        ),
        .testTarget(
            name: "VibePierAppTests",
            dependencies: ["VibePierApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "VibePierCoreTests", dependencies: ["VibePierCore", "VibeLocalization"]),
    ]
)
