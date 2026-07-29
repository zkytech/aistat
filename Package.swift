// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "agent-status",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "agent-status", targets: ["AgentStatus"])
    ],
    targets: [
        .executableTarget(
            name: "AgentStatus",
            path: "Sources/AgentStatus"
        ),
        .testTarget(
            name: "AgentStatusTests",
            dependencies: ["AgentStatus"],
            path: "Tests/AgentStatusTests"
        )
    ]
)
