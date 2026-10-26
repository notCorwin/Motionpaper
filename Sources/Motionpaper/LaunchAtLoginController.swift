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

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    // The system is the source of truth; constructing the controller never registers the app.
    var status: SMAppService.Status { service.status }

    func toggle() async throws {
        switch service.status {
        case .enabled, .requiresApproval:
            try await service.unregister()
        default:
            try service.register()
        }
    }
}
