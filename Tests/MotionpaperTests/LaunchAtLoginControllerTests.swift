import Foundation
import ServiceManagement
import Testing
@testable import Motionpaper

private enum LoginItemFailure: LocalizedError {
    case denied

    var errorDescription: String? { "Login item change denied" }
}

@MainActor
private final class LoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var registrations = 0
    var unregistrations = 0
    var failure: (any Error)?
    var statusAfterFailure: SMAppService.Status?
    var onRegister: (() -> Void)?

    func register() throws {
        registrations += 1
        onRegister?()
        if let failure {
            if let statusAfterFailure { status = statusAfterFailure }
            throw failure
        }
        status = registrationStatus
    }

    func unregister() async throws {
        unregistrations += 1
        if let failure {
            if let statusAfterFailure { status = statusAfterFailure }
            throw failure
        }
        status = .notRegistered
    }
}

@Test @MainActor
func launchAtLoginStartsDisabledWithoutRegistering() {
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    #expect(controller.status == .notRegistered)
    #expect(service.registrations == 0)
    #expect(service.unregistrations == 0)
}

@Test @MainActor
func launchAtLoginCanBeEnabledAndDisabled() async throws {
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    try await controller.toggle()
    #expect(controller.status == .enabled)
    try await controller.toggle()
    #expect(controller.status == .notRegistered)
    #expect(service.registrations == 1)
    #expect(service.unregistrations == 1)
}

@Test @MainActor
func aNewLoginItemCanBeRegisteredBeforeTheSystemFindsIt() async throws {
    let service = LoginItem()
    service.status = .notFound
    let controller = LaunchAtLoginController(service: service)
    #expect(service.registrations == 0)
    try await controller.toggle()
    #expect(controller.status == .enabled)
    #expect(service.registrations == 1)
}

@Test @MainActor
func pendingApprovalIsReportedAndCanBeCancelled() async throws {
    let service = LoginItem()
    service.registrationStatus = .requiresApproval
    let controller = LaunchAtLoginController(service: service)
    try await controller.toggle()
    #expect(controller.status == .requiresApproval)
    try await controller.toggle()
    #expect(controller.status == .notRegistered)
    #expect(service.registrations == 1)
    #expect(service.unregistrations == 1)
}

@Test @MainActor
func changesInSystemSettingsDetermineTheNextAction() async throws {
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    service.status = .enabled
    #expect(controller.status == .enabled)
    try await controller.toggle()
    #expect(service.registrations == 0)
    #expect(service.unregistrations == 1)
    #expect(controller.status == .notRegistered)
}

@Test @MainActor
func failedLoginItemChangesPreserveTheSystemState() async {
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    service.failure = LoginItemFailure.denied
    await #expect(throws: LoginItemFailure.denied) { try await controller.toggle() }
    #expect(controller.status == .notRegistered)
    #expect(controller.failureMessage == "Login item change denied")
    #expect(controller.failureMessage == "Login item change denied")
    service.status = .enabled
    await #expect(throws: LoginItemFailure.denied) { try await controller.toggle() }
    #expect(controller.status == .enabled)
    #expect(controller.failureMessage == "Login item change denied")
}

@Test @MainActor
func loginItemFailureExpiresWhenSystemStateChanges() async {
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    service.failure = LoginItemFailure.denied
    await #expect(throws: LoginItemFailure.denied) { try await controller.toggle() }
    #expect(controller.failureMessage == "Login item change denied")

    service.status = .enabled
    #expect(controller.failureMessage == nil)
    service.status = .notRegistered
    #expect(controller.failureMessage == nil)
}

@Test @MainActor
func successfulLoginItemRetryClearsFailureBeforeStarting() async throws {
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    service.failure = LoginItemFailure.denied
    await #expect(throws: LoginItemFailure.denied) { try await controller.toggle() }
    #expect(controller.failureMessage == "Login item change denied")

    service.failure = nil
    service.onRegister = { [weak controller] in
        #expect(controller?.failureMessage == nil)
    }
    try await controller.toggle()
    #expect(controller.status == .enabled)
    #expect(controller.failureMessage == nil)
    #expect(service.registrations == 2)
}

@Test @MainActor
func loginItemFailureIsDiscardedIfTheOperationChangedTheSystemState() async {
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    service.failure = LoginItemFailure.denied
    service.statusAfterFailure = .enabled
    await #expect(throws: LoginItemFailure.denied) { try await controller.toggle() }
    #expect(controller.status == .enabled)
    #expect(controller.failureMessage == nil)

    service.statusAfterFailure = .notRegistered
    await #expect(throws: LoginItemFailure.denied) { try await controller.toggle() }
    #expect(controller.status == .notRegistered)
    service.status = .enabled
    #expect(controller.failureMessage == nil)
    #expect(service.registrations == 1)
    #expect(service.unregistrations == 1)
}

@Test @MainActor
func loginItemActionFollowsCurrentSystemStateAfterFailure() async throws {
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    service.failure = LoginItemFailure.denied
    await #expect(throws: LoginItemFailure.denied) { try await controller.toggle() }
    #expect(controller.failureMessage == "Login item change denied")

    service.status = .enabled
    service.failure = nil
    try await controller.toggle()
    #expect(controller.status == .notRegistered)
    #expect(controller.failureMessage == nil)
    #expect(service.registrations == 1)
    #expect(service.unregistrations == 1)

    service.status = .enabled
    service.failure = LoginItemFailure.denied
    await #expect(throws: LoginItemFailure.denied) { try await controller.toggle() }
    #expect(controller.failureMessage == "Login item change denied")
    service.status = .notRegistered
    service.failure = nil
    try await controller.toggle()
    #expect(controller.status == .enabled)
    #expect(controller.failureMessage == nil)
    #expect(service.registrations == 2)
    #expect(service.unregistrations == 2)
}
