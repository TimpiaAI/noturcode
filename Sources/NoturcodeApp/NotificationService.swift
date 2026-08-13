import Foundation
import NoturcodeCore
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onSessionSelected: (@MainActor (SessionKey) -> Void)?
    private var prepared = false

    func prepare() {
        guard !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                NSLog("Noturcode notification authorization failed: %@", error.localizedDescription)
            } else if !granted {
                NSLog("Noturcode notifications are disabled in System Settings")
            }
        }
    }

    func notifyDone(_ session: TrackedSession) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.name) is done"
        content.body = session.lastAgentMessage ?? "The session finished replying."
        content.threadIdentifier = session.key.description
        content.userInfo = NotificationRoute.metadata(for: session.key)
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Noturcode notification delivery failed: %@", error.localizedDescription) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let metadata = response.notification.request.content.userInfo
        let key = NotificationRoute.sessionKey(
            source: metadata[NotificationRoute.sourceKey] as? String,
            sessionID: metadata[NotificationRoute.sessionIDKey] as? String
        )
        guard let key else { return }
        Task { @MainActor [weak self] in
            self?.onSessionSelected?(key)
        }
    }
}
