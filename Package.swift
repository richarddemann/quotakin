// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Quotakin",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "Quotakin", targets: ["UsageBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "UsageCore", dependencies: ["CSQLite"]),
        .executableTarget(
            name: "UsageBar",
            dependencies: [
                "UsageCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources/ProviderIcons"),
                .copy("Resources/UsageBar.icns"),
                .copy("Resources/Pets")
            ]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "UsageBarTests",
            dependencies: ["UsageBar"]
        )
    ]
)
