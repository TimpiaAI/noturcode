import Foundation

public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case gemini
    case opencode
    case grok
    case harness

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        case .grok: "Grok"
        case .harness: "Harness"
        }
    }
}

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case idle
    case working
    case askingYou
    case done
    case failed

    public var displayName: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .askingYou: "ASKING YOU"
        case .done: "DONE"
        case .failed: "FAILED"
        }
    }

    public var needsAttention: Bool {
        self == .askingYou || self == .done || self == .failed
    }

    public var showsCompletionSummary: Bool {
        self == .askingYou || self == .done
    }
}

public struct ProviderFailurePresentation: Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    public static func parse(_ raw: String) -> ProviderFailurePresentation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = trimmed.lowercased()
        let isProviderEnvelope = lowercase.contains("invalid_request_error")
            || lowercase.contains("rate_limit_error")
            || lowercase.range(of: #"^[45][0-9][0-9]\s*\{"#, options: .regularExpression) != nil
        guard isProviderEnvelope || lowercase.contains("prompt is too long") else { return nil }

        let providerMessage = nestedProviderMessage(in: trimmed)
        let normalized = (providerMessage ?? trimmed).lowercased()
        if normalized.contains("prompt is too long") {
            return ProviderFailurePresentation(
                title: "Context limit reached",
                message: "This session is larger than the provider allows. If compaction cannot complete, continue in a new session."
            )
        }
        if normalized.contains("rate limit") || normalized.contains("rate_limit") {
            return ProviderFailurePresentation(
                title: "Rate limit reached",
                message: "The provider temporarily rejected this request. Wait briefly, then try again."
            )
        }
        if let providerMessage, !providerMessage.isEmpty {
            return ProviderFailurePresentation(
                title: "Provider request failed",
                message: String(providerMessage.prefix(240))
            )
        }
        return ProviderFailurePresentation(
            title: "Provider request failed",
            message: "The provider rejected this request. Open the CLI for additional recovery options."
        )
    }

    private static func nestedProviderMessage(in raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        let json = String(raw[start...])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SessionKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var source: AgentSource
    public var sessionID: String

    public init(source: AgentSource, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
    }

    public var description: String { "\(source.rawValue):\(sessionID)" }
}

public struct TerminalTarget: Codable, Equatable, Sendable {
    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    public var uniqueID: String {
        sessionID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? sessionID
    }

    public var revealURL: URL? {
        guard !sessionID.hasPrefix("terminal:") else { return nil }
        var components = URLComponents()
        components.scheme = "iterm2"
        components.host = ""
        components.path = "/reveal"
        components.queryItems = [URLQueryItem(name: "sessionid", value: sessionID)]
        return components.url
    }
}

public struct SubagentSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var state: SessionState
    public var activity: String
    public var startedAt: Date
    public var updatedAt: Date
    public var tokens: Int?
    public var lastMessage: String?

    public init(
        id: String,
        type: String,
        state: SessionState = .working,
        activity: String = "working",
        startedAt: Date,
        updatedAt: Date,
        tokens: Int? = nil,
        lastMessage: String? = nil
    ) {
        self.id = id
        self.type = type
        self.state = state
        self.activity = activity
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.tokens = tokens
        self.lastMessage = lastMessage
    }
}

public struct ActivitySnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: String, label: String, startedAt: Date, finishedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct TrackedSession: Identifiable, Codable, Equatable, Sendable {
    public var key: SessionKey
    public var name: String
    public var terminal: TerminalTarget
    public var sourceProcessID: Int32?
    public var cwd: String?
    public var transcriptPath: String?
    public var state: SessionState
    public var connectedAt: Date
    public var lastPromptAt: Date
    public var stateChangedAt: Date
    public var lastAgentMessage: String?
    public var tokens: Int?
    public var currentActivity: String?
    public var activityStartedAt: Date?
    public var recentActivities: [ActivitySnapshot]?
    public var subagents: [SubagentSnapshot]
    public var staleTargetMessage: String?

    public var id: String { key.description }

    public init(
        key: SessionKey,
        name: String,
        terminal: TerminalTarget,
        sourceProcessID: Int32?,
        cwd: String?,
        transcriptPath: String? = nil,
        state: SessionState = .idle,
        connectedAt: Date,
        lastPromptAt: Date,
        stateChangedAt: Date,
        lastAgentMessage: String? = nil,
        tokens: Int? = nil,
        currentActivity: String? = nil,
        activityStartedAt: Date? = nil,
        recentActivities: [ActivitySnapshot] = [],
        subagents: [SubagentSnapshot] = [],
        staleTargetMessage: String? = nil
    ) {
        self.key = key
        self.name = name
        self.terminal = terminal
        self.sourceProcessID = sourceProcessID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.state = state
        self.connectedAt = connectedAt
        self.lastPromptAt = lastPromptAt
        self.stateChangedAt = stateChangedAt
        self.lastAgentMessage = lastAgentMessage
        self.tokens = tokens
        self.currentActivity = currentActivity
        self.activityStartedAt = activityStartedAt
        self.recentActivities = recentActivities
        self.subagents = subagents
        self.staleTargetMessage = staleTargetMessage
    }

    public var activeSubagents: [SubagentSnapshot] {
        subagents.filter { $0.state == .working || $0.state == .askingYou }
    }

    public var toolActivities: [ActivitySnapshot] {
        recentActivities ?? []
    }
}

public enum BridgeEventKind: String, Codable, Sendable {
    case connect
    case disconnect
    case promptSubmitted
    case activityStarted
    case activityFinished
    case askingYou
    case responseCompleted
    case failed
    case sessionStarted
    case sessionEnded
    case subagentStarted
    case subagentActivity
    case subagentCompleted
    case subagentFailed
}

public struct SelectionContextRequest: Codable, Equatable, Sendable {
    public let type: String
    public let selection: String
    public let terminalSessionID: String?

    public init(selection: String, terminalSessionID: String?) {
        type = "selectionContext"
        self.selection = selection
        self.terminalSessionID = terminalSessionID
    }
}

public struct BridgeEvent: Codable, Equatable, Sendable {
    public var kind: BridgeEventKind
    public var source: AgentSource
    public var sessionID: String
    public var timestamp: Date
    public var name: String?
    public var terminalSessionID: String?
    public var sourceProcessID: Int32?
    public var cwd: String?
    public var transcriptPath: String?
    public var prompt: String?
    public var message: String?
    public var activity: String?
    public var error: String?
    public var subagentID: String?
    public var subagentType: String?
    public var tokens: Int?
    public var sessionTokens: Int?

    public init(
        kind: BridgeEventKind,
        source: AgentSource,
        sessionID: String,
        timestamp: Date = Date(),
        name: String? = nil,
        terminalSessionID: String? = nil,
        sourceProcessID: Int32? = nil,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        prompt: String? = nil,
        message: String? = nil,
        activity: String? = nil,
        error: String? = nil,
        subagentID: String? = nil,
        subagentType: String? = nil,
        tokens: Int? = nil,
        sessionTokens: Int? = nil
    ) {
        self.kind = kind
        self.source = source
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.name = name
        self.terminalSessionID = terminalSessionID
        self.sourceProcessID = sourceProcessID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.prompt = prompt
        self.message = message
        self.activity = activity
        self.error = error
        self.subagentID = subagentID
        self.subagentType = subagentType
        self.tokens = tokens
        self.sessionTokens = sessionTokens
    }

    public var key: SessionKey { SessionKey(source: source, sessionID: sessionID) }
}

public struct BridgeEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var event: BridgeEvent

    public init(event: BridgeEvent) {
        self.version = Self.currentVersion
        self.event = event
    }
}

public struct SessionTransition: Equatable, Sendable {
    public var old: TrackedSession?
    public var new: TrackedSession?
    public var event: BridgeEvent

    public init(old: TrackedSession?, new: TrackedSession?, event: BridgeEvent) {
        self.old = old
        self.new = new
        self.event = event
    }
}
