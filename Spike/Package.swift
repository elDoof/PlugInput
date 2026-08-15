// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlugInputSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PlugInputSpike")
    ]
)
