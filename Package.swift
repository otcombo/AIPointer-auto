// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIPointer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "AIPointer",
            path: "AIPointer",
            resources: [
                .copy("Resources/AIPointer-Feature-1.mp4"),
                .copy("Resources/AIPointer-Feature-2.mp4"),
                .copy("Resources/AIPointer-Feature-3.mp4")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
