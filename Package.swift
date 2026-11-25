// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CIBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "CIBar", path: "Sources/CIBar")
    ],
    swiftLanguageModes: [.v5]
)
