// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIPointer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "AIPointer",
            path: "AIPointer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
