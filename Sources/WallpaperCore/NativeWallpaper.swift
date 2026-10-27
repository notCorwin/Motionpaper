import Darwin
import Foundation
import PlaybackCore

// Preserve Swift's async class-method calling convention, including swiftself.
// Never instantiate this shim: use the framework's actual class metadata.
@MainActor
private class NativeAssertionFactory {
    @_weakLinked
    @_silgen_name("$s9Wallpaper0A25PresentationModeAssertionC08takeIdleD0ACXDyYaKFZ")
    final class func takeIdleAssertion() async throws -> AnyObject
}

enum NativeWallpaperError: NonRetryablePlaybackError, Equatable, CustomStringConvertible {
    case missingFramework
    case missingSymbols([String])

    var description: String {
        switch self {
        case .missingFramework:
            return "当前系统未提供可用的壁纸框架（\(ProcessInfo.processInfo.operatingSystemVersionString)）。"
        case .missingSymbols(let symbols):
            return "当前系统的壁纸播放接口不兼容（\(ProcessInfo.processInfo.operatingSystemVersionString)），缺少：\(symbols.joined(separator: ", "))。"
        }
    }
}

enum WallpaperInterface {
    static let path = "/System/Library/PrivateFrameworks/Wallpaper.framework/Versions/A/Wallpaper"
    static let metadataSymbol = "$s9Wallpaper0A25PresentationModeAssertionCN"
    static let methodSymbol = "$s9Wallpaper0A25PresentationModeAssertionC08takeIdleD0ACXDyYaKFZ"
    static let requiredSymbols = [metadataSymbol, methodSymbol, methodSymbol + "Tu"]

    static func resolveMetadata(in library: UnsafeMutableRawPointer?,
                                findSymbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { dlsym($0, $1) }) throws -> UnsafeMutableRawPointer {
        guard let library else { throw NativeWallpaperError.missingFramework }
        let addresses = requiredSymbols.map { findSymbol(library, $0) }
        let missing = zip(requiredSymbols, addresses).compactMap { $1 == nil ? $0 : nil }
        guard missing.isEmpty, let metadata = addresses[0] else {
            throw NativeWallpaperError.missingSymbols(missing)
        }
        return metadata
    }
}

@MainActor
public final class NativeWallpaperSession: PlaybackSession {
    // The private object's superclass and reference-counting implementation
    // belong to the framework, so retain it through universal object ownership.
    private var assertion: AnyObject?

    private init(assertion: AnyObject) {
        self.assertion = assertion
    }

    // Loaded-image capabilities are immutable for this process, so cache both
    // success and failure. Keep the framework loaded until the process exits.
    private static let nativeClass: Result<NativeAssertionFactory.Type, any Error> = Result {
        // Inspect only the image dyld weak-linked at launch. Loading it for the
        // first time here would leave the already-bound weak imports null.
        let library = dlopen(WallpaperInterface.path, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD)
        let metadata = try WallpaperInterface.resolveMetadata(in: library)
        return unsafeBitCast(metadata, to: NativeAssertionFactory.Type.self)
    }

    /// Check interface availability without acquiring a playback assertion.
    public static func checkCompatibility() throws {
        _ = try nativeClass.get()
    }

    public static func acquire() async throws -> NativeWallpaperSession {
        let assertion = try await nativeClass.get().takeIdleAssertion()
        return NativeWallpaperSession(assertion: assertion)
    }

    public func release() {
        assertion = nil
    }
}
