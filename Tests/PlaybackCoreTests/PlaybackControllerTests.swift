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
func successiveFailuresRespectRetryIntervalDespiteRepeatedEnable() async throws {
    let interval = Duration.milliseconds(150)
    let session = Session()
    var acquisitions: [ContinuousClock.Instant] = []
    var retries: [ContinuousClock.Instant] = []
    var states: [PlaybackController.State] = []
    var duplicateEnablesPreservedRetryState = true
    let controller = PlaybackController(retryInterval: interval) {
        acquisitions.append(.now)
        if acquisitions.count <= 3 { throw TransientFailure.unavailable }
        return session
    }
    controller.onStateChange = { [weak controller] state in
        states.append(state)
        if case .retrying = state {
            retries.append(.now)
            controller?.setEnabled(true)
            controller?.setEnabled(true)
            duplicateEnablesPreservedRetryState = duplicateEnablesPreservedRetryState
                && controller?.state == state
        }
    }

    controller.setEnabled(true)
    for count in 1...3 {
        try await waitFor { retries.count >= count }
        try await Task.sleep(for: .milliseconds(40))
        controller.setEnabled(true)
        controller.setEnabled(true)
    }
    try await waitFor { controller.state == .enabled }
    #expect(acquisitions.count == 4)
    #expect(retries.count == 3)
    #expect(states.filter { $0 == .starting }.count == 1)
    #expect(duplicateEnablesPreservedRetryState)
    if acquisitions.count == 4, retries.count == 3 {
        for (retry, acquisition) in zip(retries, acquisitions.dropFirst()) {
            let elapsed = retry.duration(to: acquisition)
            // MainActor contention can delay a retry; it must never start before its interval.
            #expect(elapsed >= interval)
        }
    }
    controller.setEnabled(false)
    #expect(session.releases == 1)
}

@Test @MainActor
func disablingWhileWaitingCancelsTheRetry() async throws {
    var acquisitions = 0
    let controller = PlaybackController(retryInterval: .milliseconds(40)) {
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
func timeoutRecoversAutomaticallyAndReleasesItsLateResult() async throws {
    let old = Session()
    let current = Session()
    var pending: CheckedContinuation<any PlaybackSession, any Error>?
    var acquisitions = 0
    var retried = false
    let controller = PlaybackController(acquisitionTimeout: .milliseconds(25),
                                        retryInterval: .milliseconds(5)) {
        acquisitions += 1
        if acquisitions == 1 {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return current
    }
    controller.onStateChange = { state in
        if case .retrying = state { retried = true }
    }
    controller.setEnabled(true)
    try await waitFor { pending != nil }
    try await waitFor { controller.state == .enabled }
    #expect(acquisitions == 2)
    #expect(retried)
    pending?.resume(returning: old)
    try await waitFor { old.releases == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.state == .enabled)
    #expect(acquisitions == 2)
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
                                        retryInterval: .milliseconds(5)) {
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
    let controller = PlaybackController(retryInterval: .milliseconds(10)) {
        acquisitions += 1
        throw PermanentFailure.unavailable
    }
    controller.setEnabled(true)
    try await waitFor {
        if case .failed = controller.state { return true }
        return false
    }
    controller.setEnabled(true)
    try await Task.sleep(for: .milliseconds(30))
    if case .failed = controller.state {} else {
        Issue.record("Expected a permanent failure")
    }
    #expect(acquisitions == 1)
    controller.setEnabled(false)
    controller.setEnabled(true)
    try await waitFor {
        if case .failed = controller.state { return true }
        return false
    }
    #expect(acquisitions == 2)
    controller.setEnabled(false)
}

@Test @MainActor
func disablingFromStartingCallbackCancelsTheNotYetStartedRequest() async throws {
    var acquisitions = 0
    let controller = PlaybackController(acquisitionTimeout: .milliseconds(15),
                                        retryInterval: .milliseconds(5)) {
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
    let controller = PlaybackController(retryInterval: .milliseconds(30)) {
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
