import AppKit
import Combine
import Foundation
import NoturcodeCore

enum NativeAgentProvider {
    case codex
    case gemini
    case grok

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .grok: "Grok"
        }
    }
}

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

    private struct TranscriptFingerprint: Equatable, Sendable {
        let revision: TranscriptFileRevision
        let lastPromptAt: Date
    }

    private struct TranscriptObservation: Sendable {
        let candidate: TranscriptCandidate
        let fingerprint: TranscriptFingerprint
        let state: TranscriptTurnState
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
    let terminalPromptSender = ITermPromptSender()
    nonisolated let remoteImageRelay = RemoteImageRelayStore()
    lazy var remoteImagePaste = RemoteImagePasteCoordinator(
        terminalSender: terminalPromptSender,
        relay: remoteImageRelay
    )
    lazy var nativeSessions = NativeSessionCoordinator { [weak self] event in
        await MainActor.run { self?.receive(event) }
    }
    lazy var promptSender = SessionPromptRouter(
        terminalSender: terminalPromptSender,
        nativeSessions: nativeSessions
    )
    let terminalWindows = TerminalViewportWindowCoordinator()
    let filePreviews = FilePreviewWindowCoordinator()
    let completionReads = CompletionReadStore()
    let selectionQuestions = SelectionQuestionCoordinator()
    nonisolated let remoteBridge = RemoteBridgeProcessor()
    nonisolated let remoteTerminalRegistry: RemoteTerminalRegistry

    private var socketServer: UnixSocketServer?
    private var processMonitor: SessionProcessMonitor?
    private var displayCoordinator: DisplayCoordinator?
    private var askingEscalations: [SessionKey: Task<Void, Never>] = [:]
    private var staleMessageTask: Task<Void, Never>?
    private var transcriptReconciliationTask: Task<Void, Never>?
    private var transcriptFingerprints: [SessionKey: TranscriptFingerprint] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let registry = RemoteTerminalRegistry()
        remoteTerminalRegistry = registry
        store = SessionStore(recoveredRemoteSessions: registry.sessions())
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
            if let pid = session.sourceProcessID,
               Self.shouldWatchProcess(terminalSessionID: session.terminal?.sessionID) {
                processMonitor?.watch(key: session.key, pid: pid)
                Task { [weak self] in
                    guard let self,
                          let currentTarget = await self.terminalResolver.resolve(processID: pid) else { return }
                    self.store.rebindTerminal(for: session.key, to: currentTarget)
                }
            }
        }

        let server = UnixSocketServer { [weak self] data in
            if let request = try? JSONDecoder().decode(RemoteImagePollRequest.self, from: data),
               request.type == "remoteImagePoll" {
                guard let self,
                      self.remoteBridge.pairings.validates(
                        token: request.token,
                        deviceID: request.deviceID
                      ) else {
                    return Self.encodeRemoteResponse(RemoteImagePollResponse(
                        ok: false,
                        error: "This VPS is not paired with Noturcode."
                    ))
                }
                return Self.encodeRemoteResponse(self.remoteImageRelay.poll(request))
            }
            if let request = try? JSONDecoder().decode(RemoteImageReadyRequest.self, from: data),
               request.type == "remoteImageReady" {
                guard let self,
                      self.remoteBridge.pairings.validates(
                        token: request.token,
                        deviceID: request.deviceID
                      ),
                      self.remoteImageRelay.complete(request) else {
                    return Data("{\"ok\":false}".utf8)
                }
                return Data("{\"ok\":true}".utf8)
            }
            if let request = try? JSONDecoder().decode(TerminalImagePasteRequest.self, from: data),
               request.type == "terminalImagePaste" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let pasteSession = self.store.sessions.first {
                        $0.terminal?.uniqueID == request.terminalSessionID
                    }
                    do {
                        if try await self.remoteImagePaste.handle(
                            request: request,
                            sessions: self.store.sessions,
                            progress: { [weak self] stage in
                                guard let self, let pasteSession else { return }
                                self.announcements.updateRemoteImagePaste(session: pasteSession, stage: stage)
                            }
                        ) {
                            self.sounds.play(.send)
                        }
                    } catch {
                        if let pasteSession {
                            self.announcements.updateRemoteImagePaste(
                                session: pasteSession,
                                stage: .failed(message: error.localizedDescription)
                            )
                        }
                        self.showStaleMessage(error.localizedDescription)
                        self.sounds.play(.failed)
                    }
                }
                return Data("{\"ok\":true}".utf8)
            }
            if let request = try? JSONDecoder().decode(SelectionContextRequest.self, from: data),
               request.type == "selectionContext" {
                Task { @MainActor in
                    self?.selectionQuestions.show(request: request, sessions: self?.store.sessions ?? [])
                }
                return Data("{\"ok\":true}".utf8)
            }
            if let request = try? JSONDecoder().decode(RemotePairRequest.self, from: data),
               request.type == "remotePair" {
                let response = self?.remoteBridge.pair(request)
                    ?? RemotePairResponse(ok: false, error: "Noturcode is stopping.")
                return Self.encodeRemoteResponse(response)
            }
            if let request = try? JSONDecoder().decode(RemoteHookRequest.self, from: data),
               request.type == "remoteHook" {
                guard let result = self?.remoteBridge.process(request) else {
                    return Self.encodeRemoteResponse(RemoteHookResponse(ok: false, error: "Noturcode is stopping."))
                }
                let remoteEvents = result.events
                Task { @MainActor [weak self] in
                    for event in remoteEvents {
                        self?.receive(event)
                    }
                }
                return Self.encodeRemoteResponse(result.response)
            }
            guard let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data),
                  envelope.version == BridgeEnvelope.currentVersion else {
                return Data("{\"ok\":false}".utf8)
            }
            Task { @MainActor in
                self?.receive(envelope.event)
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
        let persistedSessions = store.sessions
        Task { [weak self] in
            await self?.nativeSessions.restore(persistedSessions)
        }
    }

    nonisolated private static func encodeRemoteResponse<T: Encodable>(_ response: T) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false}".utf8)
    }

    func stop() {
        askingEscalations.values.forEach { $0.cancel() }
        askingEscalations.removeAll()
        staleMessageTask?.cancel()
        transcriptReconciliationTask?.cancel()
        transcriptReconciliationTask = nil
        transcriptFingerprints.removeAll()
        displayCoordinator?.stop()
        displayCoordinator = nil
        processMonitor?.stop()
        processMonitor = nil
        terminalWindows.closeAll()
        Task { [nativeSessions] in await nativeSessions.stopAll() }
        socketServer?.stop()
        socketServer = nil
    }

    func jump(to session: TrackedSession) {
        completionReads.markSeen(session)
        guard session.terminal != nil else {
            showTerminalWindow(for: session)
            return
        }
        Task {
            guard var target = session.terminal else { return }
            var result = await navigator.reveal(target)
            if case .missing = result,
               let pid = session.sourceProcessID,
               let rebound = await terminalResolver.resolve(processID: pid) {
                target = rebound
                store.rebindTerminal(for: session.key, to: rebound)
                result = await navigator.reveal(rebound)
            }
            switch result {
            case .revealed:
                logNavigation("revealed", session: session)
                if target.applicationKind == .iterm {
                    await showPaneSpotlight(for: session)
                }
            case .missing:
                logNavigation("missing", session: session)
                let terminalName = target.applicationKind.displayName
                showStaleMessage(
                    "Could not focus \(session.name) in \(terminalName). "
                    + "The session is still connected. Try again or open its terminal manually."
                )
            case let .failed(message):
                logNavigation("failed:\(message)", session: session)
                showStaleMessage(message)
            }
        }
    }

    private func logNavigation(_ result: String, session: TrackedSession) {
        appendDiagnostic(
            "\(ISO8601DateFormatter().string(from: Date())) navigation=\(result) session=\(session.id) terminal=\(session.terminal?.uniqueID ?? "native")\n"
        )
    }

    private func showPaneSpotlight(for session: TrackedSession) async {
        do {
            try await Task.sleep(for: .milliseconds(55))
        } catch { return }

        if let frame = paneGeometryResolver.focusedPaneFrame() {
            paneHighlight.show(frame: frame, session: session)
            logSpotlight("shown", session: session, frame: frame, attempt: 1)
            return
        }
        logSpotlight("geometry-missing", session: session, frame: nil, attempt: 1)
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

    func createNativeSession(provider: NativeAgentProvider) {
        let panel = NSOpenPanel()
        panel.title = "Choose a project for \(provider.displayName)"
        panel.prompt = "Start session"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.lastPathComponent.isEmpty ? provider.displayName : url.lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            do {
                switch provider {
                case .codex:
                    _ = try await nativeSessions.startCodexSession(name: name, cwd: url.path)
                case .gemini:
                    _ = try await nativeSessions.startACPSession(provider: .gemini, name: name, cwd: url.path)
                case .grok:
                    _ = try await nativeSessions.startACPSession(provider: .grok, name: name, cwd: url.path)
                }
            } catch {
                showStaleMessage(error.localizedDescription)
            }
        }
    }

    func connectOpenCodeServer() {
        do {
            if let environmentConfiguration = try OpenCodeServerConfiguration.fromEnvironment() {
                Task { [weak self] in
                    do {
                        try await self?.nativeSessions.startOpenCode(configuration: environmentConfiguration)
                    } catch {
                        await MainActor.run { self?.showStaleMessage(error.localizedDescription) }
                    }
                }
                return
            }
        } catch {
            showStaleMessage(error.localizedDescription)
            return
        }

        let defaultsKey = "noturcode.opencode-server-url"
        let field = NSTextField(string: UserDefaults.standard.string(forKey: defaultsKey) ?? "http://127.0.0.1:4096")
        field.placeholderString = "http://127.0.0.1:4096"
        field.frame = CGRect(x: 0, y: 0, width: 340, height: 24)
        let alert = NSAlert()
        alert.messageText = "Connect OpenCode"
        alert.informativeText = "Enter the explicit localhost URL from `opencode serve`."
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let rawURL = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else {
            showStaleMessage("OpenCode URL is not valid.")
            return
        }
        do {
            let configuration = try OpenCodeServerConfiguration(baseURL: url)
            UserDefaults.standard.set(rawURL, forKey: defaultsKey)
            Task { [weak self] in
                do {
                    try await self?.nativeSessions.startOpenCode(configuration: configuration)
                } catch {
                    await MainActor.run { self?.showStaleMessage(error.localizedDescription) }
                }
            }
        } catch {
            showStaleMessage(error.localizedDescription)
        }
    }

    func saveITermWorkspace() {
        Task { [weak self] in
            do {
                let summary = try await ITermWorkspaceRunner.shared.snapshot()
                await MainActor.run {
                    self?.sounds.play(.send)
                    self?.showStaleMessage(
                        "Saved iTerm layout: \(summary.panes) panes in \(summary.windows) windows."
                    )
                }
            } catch {
                await MainActor.run {
                    self?.sounds.play(.failed)
                    self?.showStaleMessage(error.localizedDescription)
                }
            }
        }
    }

    func restoreITermWorkspace() {
        Task { [weak self] in
            do {
                let summary = try await ITermWorkspaceRunner.shared.restore()
                await MainActor.run {
                    self?.sounds.play(.send)
                    self?.showStaleMessage(
                        "Relaunched iTerm layout: \(summary.panes) panes in \(summary.windows) windows."
                    )
                }
            } catch {
                await MainActor.run {
                    self?.sounds.play(.failed)
                    self?.showStaleMessage(error.localizedDescription)
                }
            }
        }
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
        Task { [nativeSessions] in await nativeSessions.stop(session: session) }
        store.remove(session.key)
        displayCoordinator?.sessionStateDidChange()
    }

    func promptToRename(_ session: TrackedSession) {
        let field = NSTextField(string: session.name)
        field.placeholderString = "Session name"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Choose a name for this \(session.key.source.displayName) session."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = store.rename(session.key, to: field.stringValue)
    }

    private func receive(_ event: BridgeEvent) {
        let transition = store.apply(event)
        switch event.kind {
        case .disconnect, .sessionEnded:
            try? remoteTerminalRegistry.forgetSession(event.key)
        default:
            if let session = store.sessions.first(where: { $0.key == event.key }) {
                try? remoteTerminalRegistry.remember(session)
            }
        }
        switch event.kind {
        case .connect, .sessionStarted:
            if let pid = event.sourceProcessID,
               Self.shouldWatchProcess(terminalSessionID: event.terminalSessionID) {
                processMonitor?.watch(key: event.key, pid: pid)
                Task { [weak self] in
                    guard let self,
                          let currentTarget = await self.terminalResolver.resolve(processID: pid) else { return }
                    self.store.rebindTerminal(for: event.key, to: currentTarget)
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

    private static func shouldWatchProcess(terminalSessionID: String?) -> Bool {
        guard let terminalSessionID,
              let identity = TerminalIdentity.parse(sessionID: terminalSessionID) else { return true }
        return identity.remoteHost == nil
            && identity.sshTTY == nil
            && identity.sshConnection == nil
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
                          (session.key.source == .claude || session.key.source == .codex
                           || session.key.source == .pi || session.key.source == .omp),
                          let path = session.transcriptPath else { return nil }
                    return TranscriptCandidate(
                        key: session.key,
                        path: path,
                        source: session.key.source,
                        lastPromptAt: session.lastPromptAt
                    )
                }
                let activeKeys = Set(candidates.map(\.key))
                self.transcriptFingerprints = self.transcriptFingerprints.filter { activeKeys.contains($0.key) }
                let previousFingerprints = self.transcriptFingerprints
                let observations = await Task.detached(priority: .utility) {
                    candidates.compactMap { candidate -> TranscriptObservation? in
                        guard let revision = TranscriptRunStateDetector.revision(atPath: candidate.path) else {
                            return nil
                        }
                        let fingerprint = TranscriptFingerprint(
                            revision: revision,
                            lastPromptAt: candidate.lastPromptAt
                        )
                        guard previousFingerprints[candidate.key] != fingerprint else { return nil }
                        return TranscriptObservation(
                            candidate: candidate,
                            fingerprint: fingerprint,
                            state: TranscriptRunStateDetector.turnState(
                                atPath: candidate.path,
                                source: candidate.source,
                                after: candidate.lastPromptAt
                            )
                        )
                    }
                }.value
                for observation in observations {
                    let candidate = observation.candidate
                    self.transcriptFingerprints[candidate.key] = observation.fingerprint
                    guard let current = self.store.sessions.first(where: { $0.key == candidate.key }),
                          current.state == .working,
                          current.lastPromptAt == candidate.lastPromptAt else { continue }
                    switch observation.state {
                    case .active:
                        continue
                    case .completed:
                        self.receive(BridgeEvent(
                            kind: .responseCompleted,
                            source: candidate.key.source,
                            sessionID: candidate.key.sessionID
                        ))
                    case .interrupted:
                        self.receive(BridgeEvent(
                            kind: .turnInterrupted,
                            source: candidate.key.source,
                            sessionID: candidate.key.sessionID
                        ))
                    }
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

        guard let session = transition.new else {
            announcements.dismiss(sessionKey: key)
            return
        }
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
