import Foundation
import PlaybackCore
import Testing

@MainActor
private final class Session: PlaybackSession {
    private(set) var releases = 0
    func release() { releases += 1 }
}

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
func failureCanBeRetriedWithoutLeavingAnEnabledState() async throws {
    enum Failure: Error { case unavailable }
    var acquisitions = 0
    let session = Session()
    let controller = PlaybackController {
        acquisitions += 1
        if acquisitions == 1 { throw Failure.unavailable }
        return session
    }
    controller.setEnabled(true)
    try await waitFor {
        if case .failed = controller.state { return true }
        return false
    }
    controller.setEnabled(true)
    try await waitFor { controller.state == .enabled }
    #expect(acquisitions == 2)
    controller.setEnabled(false)
}

@Test @MainActor
func stalledAcquisitionTimesOutCanBeRetriedAndReleasesItsLateResult() async throws {
    let old = Session()
    let current = Session()
    var pending: CheckedContinuation<any PlaybackSession, any Error>?
    var acquisitions = 0
    let controller = PlaybackController(acquisitionTimeout: .milliseconds(25)) {
        acquisitions += 1
        if acquisitions == 1 {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return current
    }
    controller.setEnabled(true)
    try await waitFor { pending != nil }
    try await waitFor {
        if case .failed = controller.state { return true }
        return false
    }

    controller.setEnabled(true)
    try await waitFor { controller.state == .enabled }
    #expect(acquisitions == 2)
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
    let controller = PlaybackController(acquisitionTimeout: .milliseconds(25)) {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    controller.setEnabled(true)
    try await waitFor { pending != nil }
    controller.setEnabled(false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.state == .disabled)
    pending?.resume(returning: session)
    try await waitFor { session.releases == 1 }
    #expect(controller.state == .disabled)
}
