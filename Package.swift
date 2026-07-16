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
            path: "Sources/Tessera",
            linkerSettings: [
                // Embed Info.plist into the binary's __TEXT,__info_plist section
                // so the bare `swift build` executable is a menu-bar agent with a
                // bundle identity (LSUIElement + CFBundleIdentifier) — the way
                // paneru/yabai ship a single binary with no .app wrapper. This is
                // what lets Homebrew (source build) + TCC work without a bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "TesseraCoreTests",
            dependencies: ["TesseraCore"],
            path: "Tests/TesseraCoreTests"
        ),
    ]
)
