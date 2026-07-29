// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "aistat",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "aistat", targets: ["AIstat"])
    ],
    targets: [
        .executableTarget(
            name: "AIstat",
            path: "Sources/AIstat",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AIstatTests",
            dependencies: ["AIstat"],
            path: "Tests/AIstatTests"
        )
    ]
)
