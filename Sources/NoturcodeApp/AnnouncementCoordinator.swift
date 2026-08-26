import Combine
import Foundation
import NoturcodeCore

private enum AnnouncementTiming {
    static let visibleDuration: TimeInterval = 3.2
}

enum AnnouncementKind: String, Sendable {
    case done
    case asking
    case remotePaste

    var label: String {
        switch self {
        case .done: "done"
        case .asking: "needs you"
        case .remotePaste: "remote image paste"
        }
    }
}

struct AttentionAnnouncement: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionKey: SessionKey
    let name: String
    let kind: AnnouncementKind
    var remotePasteStage: RemoteImagePasteStage?
    var startedAt: Date
    var totalDuration: TimeInterval
    var remaining: TimeInterval
    var isPaused: Bool

    init(session: TrackedSession, kind: AnnouncementKind, duration: TimeInterval = AnnouncementTiming.visibleDuration) {
        id = UUID()
        sessionKey = session.key
        name = session.name
        self.kind = kind
        remotePasteStage = nil
        startedAt = Date()
        totalDuration = duration
        remaining = duration
        isPaused = false
    }

    init(session: TrackedSession, stage: RemoteImagePasteStage, duration: TimeInterval = AnnouncementTiming.visibleDuration) {
        id = UUID()
        sessionKey = session.key
        name = session.name
        kind = .remotePaste
        remotePasteStage = stage
        startedAt = Date()
        totalDuration = duration
        remaining = duration
        isPaused = false
    }

    var shouldAutoDismiss: Bool {
        true
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
    private var isHovered = false

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

    func updateRemoteImagePaste(session: TrackedSession, stage: RemoteImagePasteStage) {
        completionTask?.cancel()
        completionTask = nil
        queue.removeAll { $0.sessionKey == session.key && $0.kind == .remotePaste }

        if var active = current,
           active.sessionKey == session.key,
           active.kind == .remotePaste {
            active.remotePasteStage = stage
            active.startedAt = Date()
            active.totalDuration = AnnouncementTiming.visibleDuration
            active.remaining = AnnouncementTiming.visibleDuration
            active.isPaused = isHovered
            current = active
            if !isHovered { scheduleCompletion(after: active.remaining) }
            return
        }

        if var displaced = current {
            if !displaced.isPaused {
                displaced.remaining = max(
                    0.05,
                    displaced.remaining - Date().timeIntervalSince(displaced.startedAt)
                )
                displaced.isPaused = true
            }
            queue.insert(displaced, at: 0)
        }
        var pasteAnnouncement = AttentionAnnouncement(session: session, stage: stage)
        pasteAnnouncement.isPaused = isHovered
        current = pasteAnnouncement
        if !isHovered { scheduleCompletion(after: pasteAnnouncement.remaining) }
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
        isHovered = hovered
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
            if current.shouldAutoDismiss {
                scheduleCompletion(after: current.remaining)
            }
        }
    }

    private func showNextIfNeeded() {
        guard current == nil, !queue.isEmpty else { return }
        var next = queue.removeFirst()
        next.startedAt = Date()
        next.isPaused = isHovered
        current = next
        if next.shouldAutoDismiss, !isHovered {
            scheduleCompletion(after: next.remaining)
        }
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
