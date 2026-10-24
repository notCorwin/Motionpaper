import Darwin
import Foundation
import PlaybackCore

// These declarations mirror the verified Swift ABI of Wallpaper.framework.
// The shim is never instantiated: the call uses Apple's actual class metadata.
@MainActor
private class NativeAssertion {
    @_silgen_name("$s9Wallpaper0A25PresentationModeAssertionC08takeIdleD0ACXDyYaKFZ")
    final class func takeIdleAssertion() async throws -> NativeAssertion
}

enum NativeWallpaperError: Error, CustomStringConvertible {
    case unsupportedBuild(String)
    case missingFramework
    case missingSymbols

    var description: String {
        switch self {
        case .unsupportedBuild(let build):
            return "当前系统构建为 \(build)。此版本已验证支持 macOS 15.8.1（24H32）。"
        case .missingFramework:
            return "无法加载系统壁纸框架。"
        case .missingSymbols:
            return "系统壁纸播放接口不可用。"
        }
    }
}

@MainActor
final class NativeWallpaperSession: PlaybackSession {
    private var assertion: NativeAssertion?

    private init(assertion: NativeAssertion) {
        self.assertion = assertion
    }

    // OS build and loaded-image metadata are immutable within this process.
    // Resolve them once; only the assertion itself changes when playback toggles.
    private static let nativeClass: Result<NativeAssertion.Type, any Error> = Result {
        let build = try systemBuild()
        guard build == "24H32" else { throw NativeWallpaperError.unsupportedBuild(build) }
        let path = "/System/Library/PrivateFrameworks/Wallpaper.framework/Versions/A/Wallpaper"
        // Keep the framework loaded for the lifetime of any native assertion.
        guard let library = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            throw NativeWallpaperError.missingFramework
        }
        let metadataSymbol = "$s9Wallpaper0A25PresentationModeAssertionCN"
        let methodSymbol = "$s9Wallpaper0A25PresentationModeAssertionC08takeIdleD0ACXDyYaKFZ"
        guard let metadata = dlsym(library, metadataSymbol),
              dlsym(library, methodSymbol) != nil,
              dlsym(library, methodSymbol + "Tu") != nil else {
            throw NativeWallpaperError.missingSymbols
        }
        return unsafeBitCast(metadata, to: NativeAssertion.Type.self)
    }

    static func acquire() async throws -> NativeWallpaperSession {
        let assertion = try await nativeClass.get().takeIdleAssertion()
        return NativeWallpaperSession(assertion: assertion)
    }

    func release() {
        assertion = nil
    }

    private static func systemBuild() throws -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0 else {
            throw POSIXError(.EIO)
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else {
            throw POSIXError(.EIO)
        }
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
