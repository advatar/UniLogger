// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UniLogger",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "UniLogger",
            targets: ["UniLogger"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/inmotionsoftware/swift-log-oslog.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "UniLogger",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "LoggingOSLog", package: "swift-log-oslog")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "UniLoggerTests",
            dependencies: ["UniLogger"]
        )
    ]
)
