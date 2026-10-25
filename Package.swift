// swift-tools-version: 6.1
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Motionpaper",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Motionpaper", targets: ["Motionpaper"])],
    targets: [
        .target(name: "PlaybackCore"),
        .target(name: "UpdateCore"),
        .executableTarget(
            name: "Motionpaper",
            dependencies: ["PlaybackCore", "UpdateCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "\(root)/Support/Wallpaper.tbd"])]
        ),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"]),
        .testTarget(name: "UpdateCoreTests", dependencies: ["UpdateCore"]),
    ]
)
