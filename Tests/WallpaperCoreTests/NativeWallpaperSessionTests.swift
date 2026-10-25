import Foundation
import Testing
import WallpaperCore

// Requires a logged-in macOS session with WallpaperAgent available.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTIONPAPER_VERIFY_NATIVE_PLAYBACK"] == "1"),
      .timeLimit(.minutes(1)))
@MainActor
func nativeAssertionCanBeAcquiredReleasedAndReacquired() async throws {
    try NativeWallpaperSession.checkCompatibility()
    let first = try await NativeWallpaperSession.acquire()
    first.release()
    first.release()
    let second = try await NativeWallpaperSession.acquire()
    second.release()
}
