import Combine
import Foundation

private final class SessionPersistenceDebouncer: @unchecked Sendable {
    private let persistence: SessionPersistence
    private let queue = DispatchQueue(label: "ro.noturcode.session-persistence", qos: .utility)
    private let lock = NSLock()
    private var pendingSave: DispatchWorkItem?

    init(persistence: SessionPersistence) {
        self.persistence = persistence
    }

    func schedule(_ sessions: [TrackedSession]) {
        lock.lock()
        pendingSave?.cancel()
        let item = DispatchWorkItem { [persistence] in try? persistence.save(sessions) }
        pendingSave = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(180), execute: item)
    }

    func saveNow(_ sessions: [TrackedSession]) {
        lock.lock()
        pendingSave?.cancel()
        pendingSave = nil
        lock.unlock()
        queue.async { [persistence] in try? persistence.save(sessions) }
    }

    func flush() {
        queue.sync {}
    }
}

@MainActor
public final class SessionStore: ObservableObject {
    private static let maximumFinishedSubagents = 32

    @Published public private(set) var sessions: [TrackedSession]
    @Published public private(set) var lastStaleTargetMessage: String?

    public var transitionHandler: ((SessionTransition) -> Void)?
    private let persistence: SessionPersistence
    private let persistenceDebouncer: SessionPersistenceDebouncer

    public init(persistence: SessionPersistence = SessionPersistence()) {
        self.persistence = persistence
        self.persistenceDebouncer = SessionPersistenceDebouncer(persistence: persistence)
        self.sessions = persistence.load()
            .map(Self.pruningSubagents)
            .sorted { $0.lastPromptAt > $1.lastPromptAt }
    }

    @discardableResult
    public func apply(_ event: BridgeEvent) -> SessionTransition? {
        let key = event.key
        let index = sessions.firstIndex { $0.key == key }
        let old = index.map { sessions[$0] }

        switch event.kind {
        case .connect:
            guard let name = Self.normalizedSessionName(event.name) else { return nil }
            let terminal = event.terminalSessionID
                .flatMap { $0.isEmpty ? nil : TerminalTarget(sessionID: $0) }
                ?? old?.terminal
            let nativeSession = event.nativeSession ?? old?.nativeSession
            guard terminal != nil || nativeSession != nil else { return nil }
            let session = TrackedSession(
                key: key,
                name: name,
                terminal: terminal,
                nativeSession: nativeSession,
                sourceProcessID: event.sourceProcessID,
                cwd: event.cwd,
                transcriptPath: event.transcriptPath ?? old?.transcriptPath,
                state: old?.state ?? .idle,
                connectedAt: old?.connectedAt ?? event.timestamp,
                lastPromptAt: old?.lastPromptAt ?? event.timestamp,
                stateChangedAt: old?.stateChangedAt ?? event.timestamp,
                lastAgentMessage: old?.lastAgentMessage,
                tokens: old?.tokens,
                currentActivity: old?.currentActivity,
                activityStartedAt: old?.activityStartedAt,
                recentActivities: old?.toolActivities ?? [],
                subagents: old?.subagents ?? []
            )
            upsert(session)

        case .disconnect:
            guard let index else { return nil }
            sessions.remove(at: index)

        case .sessionEnded:
            guard var session = session(at: index) else { return nil }
            changeState(&session, to: .idle, at: event.timestamp)
            session.sourceProcessID = nil
            session.currentActivity = nil
            session.activityStartedAt = nil
            upsert(session)

        case .sessionStarted:
            guard var session = session(at: index) else {
                let terminal = event.terminalSessionID
                    .flatMap { $0.isEmpty ? nil : TerminalTarget(sessionID: $0) }
                guard terminal != nil || event.nativeSession != nil else { return nil }
                let name = Self.normalizedSessionName(event.name)
                    ?? Self.inferredSessionName(cwd: event.cwd, source: event.source)
                let newSession = TrackedSession(
                    key: key,
                    name: name,
                    terminal: terminal,
                    nativeSession: event.nativeSession,
                    sourceProcessID: event.sourceProcessID,
                    cwd: event.cwd,
                    transcriptPath: event.transcriptPath,
                    state: .idle,
                    connectedAt: event.timestamp,
                    lastPromptAt: event.timestamp,
                    stateChangedAt: event.timestamp
                )
                upsert(newSession)
                break
            }
            session.sourceProcessID = event.sourceProcessID ?? session.sourceProcessID
            session.transcriptPath = event.transcriptPath ?? session.transcriptPath
            session.name = Self.normalizedSessionName(event.name) ?? session.name
            if let terminal = event.terminalSessionID, !terminal.isEmpty {
                session.terminal = TerminalTarget(sessionID: terminal)
            }
            session.nativeSession = event.nativeSession ?? session.nativeSession
            upsert(session)

        case .promptSubmitted:
            guard var session = session(at: index) else { return nil }
            changeState(&session, to: .working, at: event.timestamp)
            session.lastPromptAt = event.timestamp
            session.transcriptPath = event.transcriptPath ?? session.transcriptPath
            session.currentActivity = "thinking"
            session.activityStartedAt = event.timestamp
            session.recentActivities = []
            upsert(session)

        case .activityStarted:
            guard var session = session(at: index) else { return nil }
            changeState(&session, to: .working, at: event.timestamp)
            session.currentActivity = event.activity ?? "working"
            session.transcriptPath = event.transcriptPath ?? session.transcriptPath
            session.activityStartedAt = event.timestamp
            recordActivityStart(&session, label: session.currentActivity ?? "working", at: event.timestamp)
            upsert(session)

        case .activityFinished:
            guard var session = session(at: index) else { return nil }
            changeState(&session, to: .working, at: event.timestamp)
            session.currentActivity = event.activity ?? "thinking"
            session.transcriptPath = event.transcriptPath ?? session.transcriptPath
            session.activityStartedAt = event.timestamp
            recordActivityFinish(&session, eventLabel: event.activity, at: event.timestamp)
            upsert(session)

        case .askingYou:
            guard var session = session(at: index) else { return nil }
            changeState(&session, to: .askingYou, at: event.timestamp)
            session.currentActivity = event.activity ?? "waiting on your answer"
            session.transcriptPath = event.transcriptPath ?? session.transcriptPath
            session.activityStartedAt = event.timestamp
            upsert(session)

        case .responseCompleted:
            guard var session = session(at: index) else { return nil }
            changeState(&session, to: .done, at: event.timestamp)
            session.lastAgentMessage = event.message ?? session.lastAgentMessage
            session.transcriptPath = event.transcriptPath ?? session.transcriptPath
            session.currentActivity = nil
            session.activityStartedAt = nil
            upsert(session)

        case .failed:
            guard var session = session(at: index) else { return nil }
            changeState(&session, to: .failed, at: event.timestamp)
            session.lastAgentMessage = event.error ?? event.message ?? session.lastAgentMessage
            session.transcriptPath = event.transcriptPath ?? session.transcriptPath
            session.currentActivity = nil
            session.activityStartedAt = nil
            upsert(session)

        case .subagentStarted, .subagentActivity, .subagentCompleted, .subagentFailed:
            guard var session = session(at: index), let subagentID = event.subagentID else { return nil }
            var subagent = session.subagents.first(where: { $0.id == subagentID }) ?? SubagentSnapshot(
                id: subagentID,
                type: event.subagentType ?? "agent",
                startedAt: event.timestamp,
                updatedAt: event.timestamp
            )
            subagent.updatedAt = event.timestamp
            subagent.type = event.subagentType ?? subagent.type
            subagent.tokens = event.tokens ?? subagent.tokens
            switch event.kind {
            case .subagentStarted:
                subagent.state = .working
                subagent.activity = event.activity ?? "working"
            case .subagentActivity:
                subagent.state = .working
                subagent.activity = event.activity ?? "working"
            case .subagentCompleted:
                subagent.state = .done
                subagent.activity = "done"
                subagent.lastMessage = event.message ?? subagent.lastMessage
            case .subagentFailed:
                subagent.state = .failed
                subagent.activity = "failed"
                subagent.lastMessage = event.error ?? event.message ?? subagent.lastMessage
            default:
                break
            }
            session.subagents.removeAll { $0.id == subagentID }
            session.subagents.append(subagent)
            session.subagents = Self.boundedSubagents(session.subagents)
            upsert(session)
        }

        if let sessionTokens = event.sessionTokens,
           let tokenIndex = sessions.firstIndex(where: { $0.key == key }) {
            let nextTokens = max(sessions[tokenIndex].tokens ?? 0, sessionTokens)
            if sessions[tokenIndex].tokens != nextTokens {
                sessions[tokenIndex].tokens = nextTokens
            }
        }

        sortSessions()
        let current = sessions.first(where: { $0.key == key })
        guard old != current else { return nil }
        persist(sessions, eventKind: event.kind)
        let transition = SessionTransition(old: old, new: current, event: event)
        transitionHandler?(transition)
        return transition
    }

    public func rebindTerminal(for key: SessionKey, to target: TerminalTarget) {
        guard let index = sessions.firstIndex(where: { $0.key == key }),
              sessions[index].terminal != target else { return }
        var session = sessions[index]
        session.terminal = target
        upsert(session)
        persistenceDebouncer.saveNow(sessions)
    }

    public func remove(_ key: SessionKey, staleMessage: String? = nil) {
        guard let index = sessions.firstIndex(where: { $0.key == key }) else { return }
        sessions.remove(at: index)
        lastStaleTargetMessage = staleMessage
        persistenceDebouncer.saveNow(sessions)
    }

    public func clearStaleMessage() {
        lastStaleTargetMessage = nil
    }

    public func showStaleMessage(_ message: String) {
        lastStaleTargetMessage = message
    }

    func flushPersistenceForTesting() {
        persistenceDebouncer.flush()
    }

    public var sortedSessions: [TrackedSession] {
        sessions.sorted { $0.lastPromptAt > $1.lastPromptAt }
    }

    private static func normalizedSessionName(_ rawName: String?) -> String? {
        rawName?
            .components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func inferredSessionName(cwd: String?, source: AgentSource) -> String {
        if let cwd {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return source.displayName
    }

    private func session(at index: Int?) -> TrackedSession? {
        guard let index else { return nil }
        return sessions[index]
    }

    private func upsert(_ session: TrackedSession) {
        if let index = sessions.firstIndex(where: { $0.key == session.key }) {
            if sessions[index] != session {
                sessions[index] = session
            }
        } else {
            sessions.append(session)
        }
    }

    private func changeState(_ session: inout TrackedSession, to state: SessionState, at timestamp: Date) {
        if session.state != state {
            session.state = state
            session.stateChangedAt = timestamp
        }
    }

    private func sortSessions() {
        let sorted = sessions.sorted { $0.lastPromptAt > $1.lastPromptAt }
        if sorted != sessions {
            sessions = sorted
        }
    }

    private func persist(_ snapshot: [TrackedSession], eventKind: BridgeEventKind) {
        switch eventKind {
        case .activityStarted, .activityFinished, .subagentStarted, .subagentActivity,
             .subagentCompleted, .subagentFailed:
            persistenceDebouncer.schedule(snapshot)
        default:
            persistenceDebouncer.saveNow(snapshot)
        }
    }

    private func recordActivityStart(_ session: inout TrackedSession, label: String, at timestamp: Date) {
        var recent = session.toolActivities
        if recent.last?.label != label {
            recent.append(ActivitySnapshot(
                id: "\(timestamp.timeIntervalSince1970)-\(recent.count)",
                label: label,
                startedAt: timestamp
            ))
        }
        session.recentActivities = Array(recent.suffix(10))
    }

    private func recordActivityFinish(_ session: inout TrackedSession, eventLabel: String?, at timestamp: Date) {
        var recent = session.toolActivities
        let normalized = eventLabel?
            .replacingOccurrences(of: "Finished · ", with: "")
            .replacingOccurrences(of: "Failed · ", with: "")
        if let index = recent.lastIndex(where: { item in
            item.finishedAt == nil && (normalized == nil || item.label == normalized)
        }) {
            recent[index].finishedAt = timestamp
        }
        session.recentActivities = recent
    }

    private static func pruningSubagents(in session: TrackedSession) -> TrackedSession {
        var session = session
        session.subagents = boundedSubagents(session.subagents)
        return session
    }

    private static func boundedSubagents(_ subagents: [SubagentSnapshot]) -> [SubagentSnapshot] {
        let active = subagents.filter { $0.state == .working || $0.state == .askingYou }
        let finished = subagents
            .filter { $0.state != .working && $0.state != .askingYou }
            .sorted { $0.updatedAt < $1.updatedAt }
            .suffix(maximumFinishedSubagents)
        return (Array(finished) + active).sorted { $0.startedAt < $1.startedAt }
    }
}
