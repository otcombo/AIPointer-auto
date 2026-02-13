// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIPointer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AIPointer",
            path: "AIPointer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
