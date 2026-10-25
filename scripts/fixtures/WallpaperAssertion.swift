import Darwin
import Foundation

#if OBJECTIVE_C_BASE
public typealias AssertionBase = NSObject
#else
@MainActor
open class AssertionBase {
    public init() {}
}
#endif

@MainActor
public class WallpaperPresentationModeAssertion: AssertionBase {
    public required override init() {
        super.init()
        record("acquired")
    }

    public class func takeIdleAssertion() async throws -> Self {
        Self.init()
    }

    deinit { record("released") }
}

private func record(_ event: String) {
    guard let path = getenv("MOTIONPAPER_ASSERTION_RELEASE_LOG") else { return }
    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    let timestamp = Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000
    let line = "\(event) \(timestamp)\n"
    _ = line.withCString { write(descriptor, $0, line.utf8.count) }
}
