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
        .executableTarget(
            name: "Wavepaper",
            dependencies: ["PlaybackCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "\(root)/Support/Wallpaper.tbd"])]
        ),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"]),
    ]
)
