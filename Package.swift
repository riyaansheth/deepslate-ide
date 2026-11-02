// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Deepslate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Deepslate", path: "Sources/Deepslate", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
