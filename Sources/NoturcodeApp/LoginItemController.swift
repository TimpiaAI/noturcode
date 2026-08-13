import Combine
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notFound
    @Published private(set) var errorMessage: String?

    func refresh() {
        status = SMAppService.mainApp.status
        persistDiagnostic()
    }

    func ensureRegistered() {
        refresh()
        guard status != .enabled, status != .requiresApproval else { return }
        do {
            try SMAppService.mainApp.register()
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            refresh()
            persistDiagnostic()
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
        persistDiagnostic()
    }

    private func persistDiagnostic() {
        let defaults = UserDefaults.standard
        defaults.set(status.rawValue, forKey: "NoturcodeLoginItemStatus")
        if let errorMessage {
            defaults.set(errorMessage, forKey: "NoturcodeLoginItemError")
        } else {
            defaults.removeObject(forKey: "NoturcodeLoginItemError")
        }
    }
}
