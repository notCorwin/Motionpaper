import Foundation
import PlaybackCore
import Testing

@MainActor
private final class Session: PlaybackSession {
    private(set) var releases = 0
    func release() { releases += 1 }
}

private enum TransientFailure: Error { case unavailable }
private enum PermanentFailure: NonRetryablePlaybackError { case unavailable }

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition())
}

@Test @MainActor
func repeatedEnableAcquiresOnceAndDisableReleasesOnce() async throws {
    let session = Session()
    var acquisitions = 0
    let controller = PlaybackController { acquisitions += 1; return session }
    controller.setEnabled(true)
    controller.setEnabled(true)
    try await waitFor { controller.state == .enabled }
    controller.setEnabled(true)
    #expect(acquisitions == 1)
    controller.setEnabled(false)
    controller.setEnabled(false)
    #expect(controller.state == .disabled)
    #expect(session.releases == 1)
}

@Test @MainActor
func disablingDuringAcquisitionReleasesTheLateResult() async throws {
    let session = Session()
    var pending: CheckedContinuation<any PlaybackSession, any Error>?
    let controller = PlaybackController {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    controller.setEnabled(true)
    try await waitFor { pending != nil }
    controller.setEnabled(false)
    pending?.resume(returning: session)
    try await waitFor { session.releases == 1 }
    #expect(controller.state == .disabled)
}

@Test @MainActor
func anOldRequestCannotReplaceANewerSession() async throws {
    let old = Session()
    let current = Session()
    var pending: CheckedContinuation<any PlaybackSession, any Error>?
    var acquisitions = 0
    let controller = PlaybackController {
        acquisitions += 1
        if acquisitions == 1 {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return current
    }
    controller.setEnabled(true)
    try await waitFor { pending != nil }
    controller.setEnabled(false)
    controller.setEnabled(true)
    try await waitFor { controller.state == .enabled }
    pending?.resume(returning: old)
    try await waitFor { old.releases == 1 }
    #expect(current.releases == 0)
    #expect(controller.state == .enabled)
    controller.setEnabled(false)
    #expect(current.releases == 1)
}

@Test @MainActor
func transientFailureRecoversAutomaticallyWithoutBypassingTheDelay() async throws {
    let delay = Duration.milliseconds(40)
    let session = Session()
    var acquisitions = 0
    var retryStarted: ContinuousClock.Instant?
    var recoveredAt: ContinuousClock.Instant?
    var stateAfterDuplicateEnable: PlaybackController.State?
    let controller = PlaybackController(retryDelays: [delay]) {
        acquisitions += 1
        if acquisitions == 1 { throw TransientFailure.unavailable }
        recoveredAt = .now
        return session
    }
    controller.onStateChange = { [weak controller] state in
        if case .retrying = state {
            retryStarted = .now
            controller?.setEnabled(true)
            controller?.setEnabled(true)
            stateAfterDuplicateEnable = controller?.state
        }
    }

    controller.setEnabled(true)
    try await waitFor { controller.state == .enabled }
    #expect(acquisitions == 2)
    #expect(stateAfterDuplicateEnable == .retrying("unavailable", after: delay))
    if let retryStarted, let recoveredAt {
        #expect(retryStarted.duration(to: recoveredAt) >= delay)
    } else {
        Issue.record("Expected a retry followed by automatic recovery")
    }
    controller.setEnabled(false)
    #expect(session.releases == 1)
}

@Test @MainActor
func retryDelaysIncreaseCapAndResetForANewEnable() async throws {
    let short = Duration.milliseconds(5)
    let long = Duration.milliseconds(10)
    let first = Session()
    let second = Session()
    var acquisitions = 0
    var delays: [Duration] = []
    let controller = PlaybackController(retryDelays: [short, long]) {
        acquisitions += 1
        if acquisitions <= 4 || acquisitions == 6 { throw TransientFailure.unavailable }
        return acquisitions == 5 ? first : second
    }
    controller.onStateChange = { state in
        if case .retrying(_, let delay) = state { delays.append(delay) }
    }

    controller.setEnabled(true)
    try await waitFor { controller.state == .enabled }
    #expect(acquisitions == 5)
    #expect(delays == [short, long, long, long])
    controller.setEnabled(false)
    #expect(first.releases == 1)
    controller.setEnabled(true)
    try await waitFor { controller.state == .enabled }
    #expect(acquisitions == 7)
    #expect(delays == [short, long, long, long, short])
    controller.setEnabled(false)
    #expect(second.releases == 1)
}

@Test @MainActor
func disablingWhileWaitingCancelsTheRetry() async throws {
    var acquisitions = 0
    let controller = PlaybackController(retryDelays: [.milliseconds(40)]) {
        acquisitions += 1
        throw TransientFailure.unavailable
    }
    controller.setEnabled(true)
    try await waitFor {
        if case .retrying = controller.state { return true }
        return false
    }
    controller.setEnabled(false)
    try await Task.sleep(for: .milliseconds(80))
    #expect(controller.state == .disabled)
    #expect(acquisitions == 1)
}

@Test @MainActor
func disablingDuringBackoffResetsTheDelayForTheNextEnable() async throws {
    let short = Duration.milliseconds(5)
    let long = Duration.milliseconds(100)
    var delays: [Duration] = []
    let controller = PlaybackController(retryDelays: [short, long]) {
        throw TransientFailure.unavailable
    }
    controller.onStateChange = { [weak controller] state in
        if case .retrying(_, let delay) = state {
            delays.append(delay)
            if delays.count >= 2 { controller?.setEnabled(false) }
        }
    }

    controller.setEnabled(true)
    try await waitFor { controller.state == .disabled }
    #expect(delays == [short, long])
    controller.setEnabled(true)
    try await waitFor { delays.count >= 3 }
    #expect(delays == [short, long, short])
    controller.setEnabled(false)
}

@Test @MainActor
func timeoutRecoversAutomaticallyAndReleasesItsLateResult() async throws {
    let old = Session()
    let current = Session()
    var pending: CheckedContinuation<any PlaybackSession, any Error>?
    var acquisitions = 0
    var retryDelays: [Duration] = []
    let controller = PlaybackController(acquisitionTimeout: .milliseconds(25),
                                        retryDelays: [.milliseconds(5), .milliseconds(10)]) {
        acquisitions += 1
        if acquisitions == 1 { throw TransientFailure.unavailable }
        if acquisitions == 2 {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return current
    }
    controller.onStateChange = { state in
        if case .retrying(_, let delay) = state { retryDelays.append(delay) }
    }
    controller.setEnabled(true)
    try await waitFor { pending != nil }
    try await waitFor { controller.state == .enabled }
    #expect(acquisitions == 3)
    #expect(retryDelays == [.milliseconds(5), .milliseconds(10)])
    pending?.resume(returning: old)
    try await waitFor { old.releases == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.state == .enabled)
    #expect(current.releases == 0)
    controller.setEnabled(false)
    #expect(current.releases == 1)
}

@Test @MainActor
func disablingAStalledAcquisitionCancelsItsDeadline() async throws {
    let session = Session()
    var pending: CheckedContinuation<any PlaybackSession, any Error>?
    var acquisitions = 0
    let controller = PlaybackController(acquisitionTimeout: .milliseconds(25),
                                        retryDelays: [.milliseconds(5)]) {
        acquisitions += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    controller.setEnabled(true)
    try await waitFor { pending != nil }
    controller.setEnabled(false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.state == .disabled)
    #expect(acquisitions == 1)
    pending?.resume(returning: session)
    try await waitFor { session.releases == 1 }
    #expect(controller.state == .disabled)
}

@Test @MainActor
func permanentFailureDoesNotRetryUntilPlaybackIsReenabled() async throws {
    var acquisitions = 0
    let controller = PlaybackController(retryDelays: [.milliseconds(10)]) {
        acquisitions += 1
        throw PermanentFailure.unavailable
    }
    controller.setEnabled(true)
    try await waitFor { controller.state == .failed("unavailable") }
    controller.setEnabled(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(controller.state == .failed("unavailable"))
    #expect(acquisitions == 1)
    controller.setEnabled(false)
    controller.setEnabled(true)
    try await waitFor { controller.state == .failed("unavailable") }
    #expect(acquisitions == 2)
    controller.setEnabled(false)
}

@Test @MainActor
func disablingFromStartingCallbackCancelsTheNotYetStartedRequest() async throws {
    var acquisitions = 0
    let controller = PlaybackController(acquisitionTimeout: .milliseconds(15),
                                        retryDelays: [.milliseconds(5)]) {
        acquisitions += 1
        return Session()
    }
    controller.onStateChange = { [weak controller] state in
        if state == .starting { controller?.setEnabled(false) }
    }
    controller.setEnabled(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(controller.state == .disabled)
    #expect(acquisitions == 0)
}

@Test @MainActor
func reentrantDisableAndEnableFromRetryCallbackCancelsTheOldRetry() async throws {
    let session = Session()
    var acquisitions = 0
    var restarted = false
    let controller = PlaybackController(retryDelays: [.milliseconds(30)]) {
        acquisitions += 1
        if acquisitions == 1 { throw TransientFailure.unavailable }
        return session
    }
    controller.onStateChange = { [weak controller] state in
        if case .retrying = state, !restarted {
            restarted = true
            controller?.setEnabled(false)
            controller?.setEnabled(true)
        }
    }
    controller.setEnabled(true)
    try await waitFor { controller.state == .enabled }
    try await Task.sleep(for: .milliseconds(60))
    #expect(restarted)
    #expect(acquisitions == 2)
    #expect(controller.state == .enabled)
    #expect(session.releases == 0)
    controller.setEnabled(false)
    #expect(session.releases == 1)
}
