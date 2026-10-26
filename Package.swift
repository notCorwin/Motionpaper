// swift-tools-version: 6.1
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Motionpaper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Motionpaper", targets: ["Motionpaper"]),
        .executable(name: "MotionpaperUpdater", targets: ["MotionpaperUpdater"]),
    ],
    targets: [
        .target(name: "PlaybackCore"),
        .target(name: "UpdateCore"),
        .target(
            name: "WallpaperCore",
            dependencies: ["PlaybackCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_library", "-Xlinker", "\(root)/Support/Wallpaper.tbd"])]
        ),
        .executableTarget(name: "MotionpaperUpdater", dependencies: ["UpdateCore"]),
        .executableTarget(
            name: "Motionpaper",
            dependencies: ["PlaybackCore", "UpdateCore", "WallpaperCore"]
        ),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"]),
        .testTarget(name: "UpdateCoreTests", dependencies: ["UpdateCore"]),
        .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore"]),
        .testTarget(name: "MotionpaperTests", dependencies: ["Motionpaper"]),
    ]
)
