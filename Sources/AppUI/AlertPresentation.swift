import AppKit

@MainActor
public enum AlertPresentation {
    public static func show(_ alert: NSAlert) {
        alert.layout()
        let window = alert.window
        // Activation and ordering alone only raise a window within its own level.
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @discardableResult
    public static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        show(alert)
        return alert.runModal()
    }
}
