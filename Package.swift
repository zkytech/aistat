// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "aistat",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "aistat", targets: ["AIstat"]),
        .executable(name: "aistat-widget", targets: ["AIstatWidget"]),
        .library(name: "AIstatShared", targets: ["AIstatShared"])
    ],
    targets: [
        .target(
            name: "AIstatShared",
            path: "Sources/AIstatShared"
        ),
        .executableTarget(
            name: "AIstat",
            dependencies: ["AIstatShared"],
            path: "Sources/AIstat",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AIstatWidget",
            dependencies: ["AIstatShared"],
            path: "Sources/AIstatWidget",
            resources: [
                // Same ProviderIcon-*.png assets as the menu-bar panel.
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-application-extension"])
            ],
            linkerSettings: [
                // SwiftPM emits a regular executable entry point. Native Xcode
                // app-extension targets enter through NSExtensionMain instead.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
                .linkedFramework("AppKit"),
                .linkedFramework("AppIntents"),
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "AIstatTests",
            dependencies: ["AIstat", "AIstatShared"],
            path: "Tests/AIstatTests"
        )
    ]
)
