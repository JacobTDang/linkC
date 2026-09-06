// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "linkC",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "linkc", targets: ["linkc"]),
        .executable(name: "linkc-mcp", targets: ["linkc-mcp"]),
        .library(name: "LinkCKit", targets: ["LinkCKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "LinkCKit",
            dependencies: ["SwiftTerm"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "linkc",
            dependencies: ["LinkCKit", "SwiftTerm"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "linkc-mcp",
            dependencies: ["LinkCKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LinkCKitTests",
            dependencies: ["LinkCKit"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
