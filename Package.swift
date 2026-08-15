// swift-tools-version: 6.0
import PackageDescription

// AudioCore imports no UI frameworks. That boundary is what keeps the model layer testable —
// the CoreAudio and AVAudioEngine binding code is not meaningfully unit-testable, so the
// pieces that *are* need somewhere to live that SwiftUI cannot reach into.
let package = Package(
    name: "PlugInput",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PlugInput", targets: ["PlugInput"]),
        .library(name: "AudioCore", targets: ["AudioCore"]),
    ],
    targets: [
        .target(name: "AudioCore"),
        .executableTarget(name: "PlugInput", dependencies: ["AudioCore"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore"]),
    ]
)
