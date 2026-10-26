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
        if let delay = getenv("MOTIONPAPER_ASSERTION_ACQUIRE_DELAY_SECONDS"),
           let seconds = Double(String(cString: delay)), seconds > 0 {
            try await Task.sleep(for: .seconds(seconds))
        }
        if let failure = getenv("MOTIONPAPER_ASSERTION_ACQUIRE_FAIL"),
           String(cString: failure) == "1" {
            record("failed")
            throw AssertionFixtureError.requestedFailure
        }
        return Self.init()
    }

    deinit { record("released") }
}

private enum AssertionFixtureError: Error {
    case requestedFailure
}

private func record(_ event: String) {
    guard let path = getenv("MOTIONPAPER_ASSERTION_RELEASE_LOG") else { return }
    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    let timestamp = Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000
    var wallTime = timespec()
    clock_gettime(CLOCK_REALTIME, &wallTime)
    let unixNanoseconds = Int64(wallTime.tv_sec) * 1_000_000_000 + Int64(wallTime.tv_nsec)
    let line = "\(event) \(timestamp) \(unixNanoseconds)\n"
    _ = line.withCString { write(descriptor, $0, line.utf8.count) }
}
