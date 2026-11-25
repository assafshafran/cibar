// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BuildBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "BuildBar", path: "Sources/BuildBar")
    ],
    swiftLanguageModes: [.v5]
)
