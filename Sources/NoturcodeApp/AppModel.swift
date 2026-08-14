import AppKit
import Combine
import Foundation
import NoturcodeCore

@MainActor
final class CompletionReadStore: ObservableObject {
    @Published private var seenCompletionTimes: [String: TimeInterval]
    private let defaults: UserDefaults
    private let storageKey = "noturcode.seen-completion-times.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seenCompletionTimes = defaults.dictionary(forKey: storageKey) as? [String: TimeInterval] ?? [:]
    }

    func isUnread(_ session: TrackedSession) -> Bool {
        guard session.state == .done else { return false }
        return (seenCompletionTimes[session.id] ?? 0) < session.stateChangedAt.timeIntervalSince1970
    }

    func markSeen(_ session: TrackedSession) {
        guard isUnread(session) else { return }
        seenCompletionTimes[session.id] = session.stateChangedAt.timeIntervalSince1970
        defaults.set(seenCompletionTimes, forKey: storageKey)
    }
}

@MainActor
final class AppModel: ObservableObject {
    private struct TranscriptCandidate: Sendable {
        let key: SessionKey
        let path: String
        let source: AgentSource
        let lastPromptAt: Date
    }

    static let shared = AppModel()

    let store: SessionStore
    let announcements = AnnouncementCoordinator()
    let notifications = NotificationService()
    let sounds = NoturcodeSoundPlayer.shared
    let loginItem = LoginItemController()
    let navigator = ITermNavigator()
    let terminalResolver = ITermSessionResolver()
    let paneGeometryResolver = ITermPaneGeometryResolver()
    let paneHighlight = TerminalPaneHighlightCoordinator()
    let transcriptReader = AgentTranscriptReader()
    let promptSender = ITermPromptSender()
    let terminalWindows = TerminalViewportWindowCoordinator()
    let filePreviews = FilePreviewWindowCoordinator()
    let completionReads = CompletionReadStore()
    let selectionQuestions = SelectionQuestionCoordinator()

    private var socketServer: UnixSocketServer?
    private var processMonitor: SessionProcessMonitor?
    private var displayCoordinator: DisplayCoordinator?
    private var askingEscalations: [SessionKey: Task<Void, Never>] = [:]
    private var staleMessageTask: Task<Void, Never>?
    private var transcriptReconciliationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        store = SessionStore()
        store.transitionHandler = { [weak self] transition in
            self?.handle(transition)
        }
        notifications.onSessionSelected = { [weak self] key in
            guard let self else { return }
            if let session = self.store.sessions.first(where: { $0.key == key }) {
                self.jump(to: session)
            } else {
                self.showStatusWindow()
            }
        }
    }

    func start() {
        guard socketServer == nil else { return }
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-test") }) {
            notifications.prepare()
        }
        loginItem.ensureRegistered()

        processMonitor = SessionProcessMonitor { [weak self] key in
            Task { @MainActor in
                self?.store.apply(BridgeEvent(
                    kind: .sessionEnded,
                    source: key.source,
                    sessionID: key.sessionID
                ))
            }
        }
        for session in store.sessions {
            if let pid = session.sourceProcessID {
                processMonitor?.watch(key: session.key, pid: pid)
                if let currentTarget = terminalResolver.resolve(processID: pid) {
                    store.rebindTerminal(for: session.key, to: currentTarget)
                }
            }
        }

        let server = UnixSocketServer { [weak self] data in
            if let request = try? JSONDecoder().decode(SelectionContextRequest.self, from: data),
               request.type == "selectionContext" {
                Task { @MainActor in
                    self?.selectionQuestions.show(request: request, sessions: self?.store.sessions ?? [])
                }
                return Data("{\"ok\":true}".utf8)
            }
            guard let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data),
                  envelope.version == BridgeEnvelope.currentVersion else {
                return Data("{\"ok\":false}".utf8)
            }
            let applicationCompleted = DispatchSemaphore(value: 0)
            Task { @MainActor in
                self?.receive(envelope.event)
                applicationCompleted.signal()
            }
            guard applicationCompleted.wait(timeout: .now() + 1.5) == .success else {
                return Data("{\"ok\":false}".utf8)
            }
            return Data("{\"ok\":true}".utf8)
        }
        do {
            try server.start()
            socketServer = server
        } catch UnixSocketError.bind(EADDRINUSE) {
            // LaunchServices normally enforces this, but test builds and direct
            // executable launches can bypass it. Never create duplicate panels.
            NSApplication.shared.terminate(nil)
            return
        } catch {
            NSLog("Noturcode socket failed: %@", error.localizedDescription)
        }

        displayCoordinator = DisplayCoordinator(model: self)
        displayCoordinator?.start()
        startTranscriptReconciliation()
    }

    func stop() {
        askingEscalations.values.forEach { $0.cancel() }
        askingEscalations.removeAll()
        staleMessageTask?.cancel()
        transcriptReconciliationTask?.cancel()
        transcriptReconciliationTask = nil
        displayCoordinator?.stop()
        displayCoordinator = nil
        processMonitor?.stop()
        processMonitor = nil
        socketServer?.stop()
        socketServer = nil
    }

    func jump(to session: TrackedSession) {
        completionReads.markSeen(session)
        Task {
            var target = session.terminal
            var result = navigator.reveal(target)
            if case .missing = result,
               let pid = session.sourceProcessID,
               let rebound = terminalResolver.resolve(processID: pid) {
                target = rebound
                store.rebindTerminal(for: session.key, to: rebound)
                result = navigator.reveal(rebound)
            }
            switch result {
            case .revealed:
                logNavigation("revealed", session: session)
                await showPaneSpotlight(for: session)
            case .missing:
                logNavigation("missing", session: session)
                showStaleMessage("\(session.name) is no longer open in iTerm2.")
                store.remove(session.key, staleMessage: "\(session.name) is no longer open in iTerm2.")
            case let .failed(message):
                logNavigation("failed:\(message)", session: session)
                showStaleMessage(message)
            }
        }
    }

    private func logNavigation(_ result: String, session: TrackedSession) {
        appendDiagnostic(
            "\(ISO8601DateFormatter().string(from: Date())) navigation=\(result) session=\(session.id) terminal=\(session.terminal.uniqueID)\n"
        )
    }

    private func showPaneSpotlight(for session: TrackedSession) async {
        do {
            try await Task.sleep(for: .milliseconds(90))
        } catch { return }

        for attempt in 0..<8 {
            if let frame = paneGeometryResolver.focusedPaneFrame() {
                paneHighlight.show(frame: frame, session: session)
                logSpotlight("shown", session: session, frame: frame, attempt: attempt + 1)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(60))
            } catch { return }
        }
        logSpotlight("geometry-missing", session: session, frame: nil, attempt: 8)
    }

    private func logSpotlight(_ result: String, session: TrackedSession, frame: CGRect?, attempt: Int) {
        let frameText = frame.map {
            "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))"
        } ?? "none"
        let line = "\(ISO8601DateFormatter().string(from: Date())) result=\(result) session=\(session.id) attempt=\(attempt) frame=\(frameText)\n"
        appendDiagnostic(line)
    }

    private func appendDiagnostic(_ line: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noturcode", isDirectory: true)
        let url = support.appendingPathComponent("spotlight.log")
        try? SecureLocalStorage.appendPrivate(Data(line.utf8), to: url)
    }

    func showStatusWindow() {
        StatusWindowController.shared.show(model: self)
    }

    func showTerminalWindow(for session: TrackedSession) {
        completionReads.markSeen(session)
        displayCoordinator?.dismissAll()
        sounds.play(.open)
        terminalWindows.show(session: session, model: self)
    }

    func disconnectFromNoturcode(_ session: TrackedSession) {
        processMonitor?.unwatch(key: session.key)
        askingEscalations[session.key]?.cancel()
        askingEscalations[session.key] = nil
        announcements.dismiss(sessionKey: session.key)
        store.remove(session.key)
        displayCoordinator?.sessionStateDidChange()
    }

    private func receive(_ event: BridgeEvent) {
        let transition = store.apply(event)
        switch event.kind {
        case .connect, .sessionStarted:
            if let pid = event.sourceProcessID {
                processMonitor?.watch(key: event.key, pid: pid)
                if let currentTarget = terminalResolver.resolve(processID: pid) {
                    store.rebindTerminal(for: event.key, to: currentTarget)
                }
            }
        case .disconnect, .sessionEnded:
            processMonitor?.unwatch(key: event.key)
        default:
            break
        }
        if transition != nil {
            displayCoordinator?.sessionStateDidChange()
        }
    }

    private func startTranscriptReconciliation() {
        transcriptReconciliationTask?.cancel()
        transcriptReconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self else { return }
                let candidates = self.store.sessions.compactMap { session -> TranscriptCandidate? in
                    guard session.state == .working,
                          let path = session.transcriptPath else { return nil }
                    return TranscriptCandidate(
                        key: session.key,
                        path: path,
                        source: session.key.source,
                        lastPromptAt: session.lastPromptAt
                    )
                }
                let completedKeys = await Task.detached(priority: .utility) {
                    candidates.compactMap { candidate in
                        TranscriptRunStateDetector.turnCompleted(
                            atPath: candidate.path,
                            source: candidate.source,
                            after: candidate.lastPromptAt
                        ) ? candidate.key : nil
                    }
                }.value
                for key in completedKeys {
                    guard let current = self.store.sessions.first(where: { $0.key == key }),
                          current.state == .working else { continue }
                    self.receive(BridgeEvent(
                        kind: .responseCompleted,
                        source: key.source,
                        sessionID: key.sessionID
                    ))
                }
            }
        }
    }

    private func handle(_ transition: SessionTransition) {
        let key = transition.event.key
        if transition.new?.state == .working || transition.new?.state == .idle {
            announcements.dismiss(sessionKey: key)
        }
        if transition.new?.state != .askingYou {
            askingEscalations[key]?.cancel()
            askingEscalations[key] = nil
        }

        guard let session = transition.new else { return }
        let oldState = transition.old?.state
        if transition.old == nil, transition.event.kind == .connect {
            sounds.play(.connect)
        }
        if session.state == .done, oldState != .done {
            sounds.play(.done)
            announcements.enqueue(session: session, kind: .done)
            notifications.notifyDone(session)
        }
        if session.state == .askingYou, oldState != .askingYou {
            sounds.play(.asking)
            askingEscalations[key]?.cancel()
            askingEscalations[key] = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(120))
                } catch {
                    return
                }
                guard let self,
                      let current = self.store.sessions.first(where: { $0.key == key }),
                      current.state == .askingYou else { return }
                self.announcements.enqueue(session: current, kind: .asking)
            }
        }
        if session.state == .failed, oldState != .failed {
            sounds.play(.failed)
        }
    }

    private func showStaleMessage(_ message: String) {
        staleMessageTask?.cancel()
        store.showStaleMessage(message)
        staleMessageTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            self?.store.clearStaleMessage()
        }
    }
}
