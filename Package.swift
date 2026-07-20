// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "linkC",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "linkc", targets: ["linkc"]),
        .library(name: "LinkCKit", targets: ["LinkCKit"]),
    ],
    targets: [
        .target(
            name: "LinkCKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "linkc",
            dependencies: ["LinkCKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LinkCKitTests",
            dependencies: ["LinkCKit"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
