// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tessera",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Pure, UI-independent geometry & layout logic. No AppKit — only
        // CoreGraphics — so it builds and unit-tests without a running app.
        .target(
            name: "TesseraCore",
            path: "Sources/TesseraCore"
        ),
        // The menu-bar agent: AppKit UI + the Accessibility engine.
        .executableTarget(
            name: "Tessera",
            dependencies: ["TesseraCore"],
            path: "Sources/Tessera"
        ),
        .testTarget(
            name: "TesseraCoreTests",
            dependencies: ["TesseraCore"],
            path: "Tests/TesseraCoreTests"
        ),
    ]
)
