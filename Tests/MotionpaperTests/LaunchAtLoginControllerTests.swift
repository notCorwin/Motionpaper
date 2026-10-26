import ServiceManagement
import Testing
@testable import Motionpaper

@MainActor
private final class LoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var registrations = 0
    var unregistrations = 0
    var failure: (any Error)?

    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = registrationStatus
    }

    func unregister() async throws {
        unregistrations += 1
        if let failure { throw failure }
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
    enum Failure: Error { case denied }
    let service = LoginItem()
    let controller = LaunchAtLoginController(service: service)
    service.failure = Failure.denied
    await #expect(throws: Failure.denied) { try await controller.toggle() }
    #expect(controller.status == .notRegistered)
    service.status = .enabled
    await #expect(throws: Failure.denied) { try await controller.toggle() }
    #expect(controller.status == .enabled)
}
