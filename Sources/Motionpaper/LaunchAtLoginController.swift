import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LaunchAtLoginController {
    private let service: any LoginItemService
    private var failure: (status: SMAppService.Status, message: String)?

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    // The system is the source of truth; constructing the controller never registers the app.
    var status: SMAppService.Status { service.status }

    var failureMessage: String? {
        guard let failure else { return nil }
        guard failure.status == service.status else {
            self.failure = nil
            return nil
        }
        return failure.message
    }

    func toggle() async throws {
        let initialStatus = service.status
        failure = nil
        do {
            switch initialStatus {
            case .enabled, .requiresApproval:
                try await service.unregister()
            default:
                try service.register()
            }
        } catch {
            if service.status == initialStatus {
                failure = (initialStatus, error.localizedDescription)
            }
            throw error
        }
    }
}
