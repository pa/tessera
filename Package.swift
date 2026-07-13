// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tessera",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Tessera",
            path: "Sources/Tessera"
        )
    ]
)
