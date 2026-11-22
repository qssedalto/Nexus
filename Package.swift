// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nexus",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Nexus", targets: ["Nexus"]),
        .library(name: "NexusCore", targets: ["NexusCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "Nexus",
            dependencies: [
                "NexusCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Nexus",
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "NexusCore",
            path: "Sources/NexusCore",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("CloudKit")]
        ),
        .testTarget(
            name: "NexusCoreTests",
            dependencies: ["NexusCore"],
            path: "Tests/NexusCoreTests"
        ),
        .testTarget(
            name: "NexusTests",
            dependencies: [
                "Nexus",
                "NexusCore",
            ],
            path: "Tests/NexusTests"
        ),
    ]
)
