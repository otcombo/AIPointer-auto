// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AIPointer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIPointer",
            path: "AIPointer"
        )
    ]
)
