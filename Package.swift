// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MA3Dashboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MA3Dashboard",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
