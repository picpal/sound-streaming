// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MacAgent",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../YoutumuKit"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
    ],
    targets: [
        .target(name: "MacAgentCore", dependencies: [
            "YoutumuKit",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        .executableTarget(name: "MacAgent", dependencies: ["MacAgentCore", "YoutumuKit"]),
        .testTarget(name: "MacAgentTests", dependencies: ["MacAgentCore", "YoutumuKit"]),
    ]
)
