import Combine
import Foundation
import NoturcodeCore

enum AnnouncementKind: String, Sendable {
    case done
    case asking

    var label: String {
        switch self {
        case .done: "done"
        case .asking: "needs you"
        }
    }
}

struct AttentionAnnouncement: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionKey: SessionKey
    let name: String
    let kind: AnnouncementKind
    var startedAt: Date
    let totalDuration: TimeInterval
    var remaining: TimeInterval
    var isPaused: Bool

    init(session: TrackedSession, kind: AnnouncementKind, duration: TimeInterval = 4.8) {
        id = UUID()
        sessionKey = session.key
        name = session.name
        self.kind = kind
        startedAt = Date()
        totalDuration = duration
        remaining = duration
        isPaused = false
    }

    func progress(at date: Date) -> Double {
        guard totalDuration > 0 else { return 0 }
        guard !isPaused else { return max(0, min(1, remaining / totalDuration)) }
        return max(0, min(1, (remaining - date.timeIntervalSince(startedAt)) / totalDuration))
    }
}

@MainActor
final class AnnouncementCoordinator: ObservableObject {
    @Published private(set) var current: AttentionAnnouncement?
    private var queue: [AttentionAnnouncement] = []
    private var completionTask: Task<Void, Never>?

    func enqueue(session: TrackedSession, kind: AnnouncementKind) {
        queue.removeAll { $0.sessionKey == session.key }
        if current?.sessionKey == session.key {
            completionTask?.cancel()
            completionTask = nil
            current = nil
        }
        queue.append(AttentionAnnouncement(session: session, kind: kind))
        showNextIfNeeded()
    }

    func dismiss(sessionKey: SessionKey) {
        queue.removeAll { $0.sessionKey == sessionKey }
        guard current?.sessionKey == sessionKey else { return }
        completionTask?.cancel()
        completionTask = nil
        current = nil
        showNextIfNeeded()
    }

    func setHovered(_ hovered: Bool) {
        guard var current else { return }
        if hovered, !current.isPaused {
            current.remaining = max(0.05, current.remaining - Date().timeIntervalSince(current.startedAt))
            current.isPaused = true
            self.current = current
            completionTask?.cancel()
            completionTask = nil
        } else if !hovered, current.isPaused {
            current.startedAt = Date()
            current.isPaused = false
            self.current = current
            scheduleCompletion(after: current.remaining)
        }
    }

    private func showNextIfNeeded() {
        guard current == nil, !queue.isEmpty else { return }
        var next = queue.removeFirst()
        next.startedAt = Date()
        current = next
        scheduleCompletion(after: next.remaining)
    }

    private func scheduleCompletion(after duration: TimeInterval) {
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard let self else { return }
            self.current = nil
            self.completionTask = nil
            self.showNextIfNeeded()
        }
    }
}
