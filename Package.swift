// swift-tools-version: 6.1
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Wavepaper",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Wavepaper", targets: ["Wavepaper"])],
    targets: [
        .target(name: "PlaybackCore"),
        .target(name: "UpdateCore"),
        .executableTarget(
            name: "Wavepaper",
            dependencies: ["PlaybackCore", "UpdateCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "\(root)/Support/Wallpaper.tbd"])]
        ),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"]),
        .testTarget(name: "UpdateCoreTests", dependencies: ["UpdateCore"]),
    ]
)
