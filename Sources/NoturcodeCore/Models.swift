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
    /// This remains the only encoded field on a target. Older session files
    /// contain only this value, so the exact native session ID stays readable
    /// and decodable without a migration.
    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    public var identity: TerminalIdentity? {
        TerminalIdentity.parse(sessionID: sessionID)
    }

    public var uniqueID: String {
        if let identity {
            if identity.application == .iterm,
               let nativeSessionID = identity.nativeSessionID {
                // TERM_SESSION_ID includes an iTerm layout prefix such as
                // `w0t0p3:`. AppleScript's `unique ID` contains only the UUID.
                return nativeSessionID.split(separator: ":").last.map(String.init)
                    ?? nativeSessionID
            }
            return identity.nativeSessionID
                ?? identity.tmuxPane
                ?? identity.zellijPaneID
                ?? identity.weztermPane
                ?? identity.kittyWindowID
                ?? identity.tty
                ?? sessionID
        }
        return sessionID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? sessionID
    }

    public var revealURL: URL? {
        guard applicationKind == .iterm, identity?.multiplexer == nil else { return nil }
        var components = URLComponents()
        components.scheme = "iterm2"
        components.host = ""
        components.path = "/reveal"
        components.queryItems = [URLQueryItem(name: "sessionid", value: sessionID)]
        return components.url
    }

    public var applicationKind: TerminalApplicationKind {
        if let identity { return identity.application }
        return sessionID.hasPrefix("terminal:") ? .unknown : .iterm
    }

    public var multiplexer: TerminalMultiplexerKind? {
        identity?.multiplexer
    }

    public var tty: String? {
        identity?.tty
    }

    public var processID: Int32? {
        identity?.processID
    }

    public var remoteSocket: String? {
        identity?.remoteSocket
    }

    public var exactIdentifier: String? {
        identity?.exactIdentifier
    }
}

public enum TerminalApplicationKind: String, Codable, CaseIterable, Sendable {
    case iterm
    case terminal
    case ghostty
    case warp
    case wezterm
    case kitty
    case unknown

    public var displayName: String {
        switch self {
        case .iterm: "iTerm2"
        case .terminal: "Terminal"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        case .wezterm: "WezTerm"
        case .kitty: "kitty"
        case .unknown: "Terminal"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .iterm: "com.googlecode.iterm2"
        case .terminal: "com.apple.Terminal"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        case .wezterm: "com.github.wez.wezterm"
        case .kitty: "net.kovidgoyal.kitty"
        case .unknown: nil
        }
    }

    public static func detect(bundleIdentifier: String?, terminalProgram: String?) -> TerminalApplicationKind {
        let value = (bundleIdentifier ?? terminalProgram ?? "").lowercased()
        if value.contains("iterm") { return .iterm }
        if value.contains("ghostty") { return .ghostty }
        if value.contains("warp") { return .warp }
        if value.contains("wezterm") || value.contains("wez.term") { return .wezterm }
        if value.contains("kitty") { return .kitty }
        if value.contains("terminal") || value.contains("apple_terminal") { return .terminal }
        return .unknown
    }
}

public enum TerminalMultiplexerKind: String, Codable, CaseIterable, Sendable {
    case tmux
    case zellij
}

/// The environment values that identify one terminal surface and, where
/// possible, one multiplexer pane. The canonical session ID is deliberately
/// compact and human-readable because it is stored in existing session files.
public struct TerminalIdentity: Codable, Equatable, Sendable {
    public var application: TerminalApplicationKind
    public var multiplexer: TerminalMultiplexerKind?
    public var nativeSessionID: String?
    public var terminalProgram: String?
    public var tty: String?
    public var processID: Int32?
    public var bundleIdentifier: String?
    public var weztermPane: String?
    public var weztermUnixSocket: String?
    public var kittyWindowID: String?
    public var kittyRemoteSocket: String?
    public var tmux: String?
    public var tmuxSocket: String?
    public var tmuxPane: String?
    public var zellijSessionName: String?
    public var zellijPaneID: String?
    public var sshTTY: String?
    public var sshConnection: String?
    public var remoteHost: String?

    public init(
        application: TerminalApplicationKind,
        multiplexer: TerminalMultiplexerKind? = nil,
        nativeSessionID: String? = nil,
        terminalProgram: String? = nil,
        tty: String? = nil,
        processID: Int32? = nil,
        bundleIdentifier: String? = nil,
        weztermPane: String? = nil,
        weztermUnixSocket: String? = nil,
        kittyWindowID: String? = nil,
        kittyRemoteSocket: String? = nil,
        tmux: String? = nil,
        tmuxSocket: String? = nil,
        tmuxPane: String? = nil,
        zellijSessionName: String? = nil,
        zellijPaneID: String? = nil,
        sshTTY: String? = nil,
        sshConnection: String? = nil,
        remoteHost: String? = nil
    ) {
        self.application = application
        self.multiplexer = multiplexer
        self.nativeSessionID = nativeSessionID
        self.terminalProgram = terminalProgram
        self.tty = tty
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.weztermPane = weztermPane
        self.weztermUnixSocket = weztermUnixSocket
        self.kittyWindowID = kittyWindowID
        self.kittyRemoteSocket = kittyRemoteSocket
        self.tmux = tmux
        self.tmuxSocket = tmuxSocket
        self.tmuxPane = tmuxPane
        self.zellijSessionName = zellijSessionName
        self.zellijPaneID = zellijPaneID
        self.sshTTY = sshTTY
        self.sshConnection = sshConnection
        self.remoteHost = remoteHost
    }

    public var exactIdentifier: String? {
        switch multiplexer {
        case .tmux: return tmuxPane
        case .zellij: return zellijPaneID
        case nil:
            switch application {
            case .wezterm: return weztermPane
            case .kitty: return kittyWindowID
            case .iterm: return nativeSessionID
            case .ghostty, .terminal, .warp, .unknown: return tty
            }
        }
    }

    public var remoteSocket: String? {
        switch application {
        case .wezterm: return weztermUnixSocket
        case .kitty: return kittyRemoteSocket
        default: return nil
        }
    }

    /// The stable value sent through the old BridgeEvent. Existing iTerm IDs
    /// remain byte-for-byte unchanged when no extra identity is needed.
    public var sessionID: String {
        if multiplexer == nil,
           application == .iterm,
           let nativeSessionID,
           bundleIdentifier == nil,
           sshTTY == nil,
           sshConnection == nil,
           remoteHost == nil {
            return nativeSessionID
        }

        if multiplexer == nil,
           application == .terminal,
           let tty,
           bundleIdentifier == nil,
           sshTTY == nil,
           sshConnection == nil,
           weztermPane == nil,
           kittyWindowID == nil {
            return "terminal:\(terminalProgram ?? "terminal"):\(Self.encode(tty))"
        }

        let resource: String
        switch multiplexer {
        case .tmux:
            resource = "tmux:\(tmuxPane.map(Self.encode) ?? "unknown")"
        case .zellij:
            resource = "zellij:\(zellijPaneID.map(Self.encode) ?? "unknown")"
        case nil:
            if application == .iterm, let nativeSessionID {
                resource = "session:\(Self.encode(nativeSessionID))"
            } else if application == .wezterm, let weztermPane {
                resource = "pane:\(Self.encode(weztermPane))"
            } else if application == .kitty, let kittyWindowID {
                resource = "window:\(Self.encode(kittyWindowID))"
            } else if let tty, !tty.isEmpty {
                resource = "tty:\(Self.encode(tty))"
            } else if let processID, processID > 0 {
                resource = "pid-\(processID)"
            } else {
                resource = "unknown"
            }
        }

        var query: [(String, String)] = []
        if let bundleIdentifier, !bundleIdentifier.isEmpty, application != .iterm {
            query.append(("bundle", bundleIdentifier))
        }
        if let processID, processID > 0, application == .ghostty {
            query.append(("pid", String(processID)))
        }
        if let tty, !tty.isEmpty, !resource.hasPrefix("tty:") {
            query.append(("tty", tty))
        }
        if let weztermUnixSocket, !weztermUnixSocket.isEmpty {
            query.append(("socket", weztermUnixSocket))
        }
        if let kittyRemoteSocket, !kittyRemoteSocket.isEmpty {
            query.append(("socket", kittyRemoteSocket))
        }
        if let tmux, !tmux.isEmpty {
            query.append(("tmux", tmux))
        }
        if let tmuxSocket, !tmuxSocket.isEmpty {
            query.append(("tmuxSocket", tmuxSocket))
        }
        if let zellijSessionName, !zellijSessionName.isEmpty {
            query.append(("session", zellijSessionName))
        }
        if let sshTTY, !sshTTY.isEmpty {
            query.append(("sshTTY", sshTTY))
        }
        if let sshConnection, !sshConnection.isEmpty {
            query.append(("sshConnection", sshConnection))
        }
        if let remoteHost, !remoteHost.isEmpty {
            query.append(("remoteHost", remoteHost))
        }

        let suffix = query.isEmpty
            ? ""
            : "?" + query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        return "terminal:\(application.rawValue):\(resource)\(suffix)"
    }

    public static func capture(environment: [String: String], sourceProcessID: Int32? = nil) -> TerminalIdentity? {
        func value(_ key: String) -> String? {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }

        let bundleIdentifier = value("__CFBundleIdentifier")
        let terminalProgram = value("TERM_PROGRAM") ?? value("LC_TERMINAL") ?? value("TERMINAL_EMULATOR")
        let application = TerminalApplicationKind.detect(
            bundleIdentifier: bundleIdentifier,
            terminalProgram: terminalProgram
        )
        let nativeSessionID = value("TERM_SESSION_ID")
        let tty = value("TTY") ?? value("SSH_TTY")
        let weztermPane = value("WEZTERM_PANE")
        let weztermUnixSocket = value("WEZTERM_UNIX_SOCKET")
        let kittyWindowID = value("KITTY_WINDOW_ID")
        let kittyRemoteSocket = value("KITTY_LISTEN_ON")
        let tmux = value("TMUX")
        let tmuxPane = value("TMUX_PANE")
        let zellijSessionName = value("ZELLIJ_SESSION_NAME")
        let zellijPaneID = value("ZELLIJ_PANE_ID")
        let sshTTY = value("SSH_TTY")
        let sshConnection = value("SSH_CONNECTION")
        let remoteHost = value("NOTURCODE_REMOTE_HOST")
        let multiplexer: TerminalMultiplexerKind?
        if tmux != nil || tmuxPane != nil {
            multiplexer = .tmux
        } else if zellijSessionName != nil || zellijPaneID != nil {
            multiplexer = .zellij
        } else {
            multiplexer = nil
        }

        let hasIdentity = nativeSessionID != nil
            || weztermPane != nil
            || weztermUnixSocket != nil
            || kittyWindowID != nil
            || tmux != nil
            || tmuxPane != nil
            || zellijSessionName != nil
            || zellijPaneID != nil
            || tty != nil
            || sourceProcessID.map({ $0 > 0 }) == true
        guard hasIdentity else { return nil }

        let tmuxSocket = tmux?.split(separator: ",", maxSplits: 1).first.map(String.init)
        return TerminalIdentity(
            application: application == .unknown && nativeSessionID != nil ? .iterm : application,
            multiplexer: multiplexer,
            nativeSessionID: nativeSessionID,
            terminalProgram: terminalProgram,
            tty: tty,
            processID: sourceProcessID,
            bundleIdentifier: bundleIdentifier,
            weztermPane: weztermPane,
            weztermUnixSocket: weztermUnixSocket,
            kittyWindowID: kittyWindowID,
            kittyRemoteSocket: kittyRemoteSocket,
            tmux: tmux,
            tmuxSocket: tmuxSocket,
            tmuxPane: tmuxPane,
            zellijSessionName: zellijSessionName,
            zellijPaneID: zellijPaneID,
            sshTTY: sshTTY,
            sshConnection: sshConnection,
            remoteHost: remoteHost
        )
    }

    public static func parse(sessionID: String) -> TerminalIdentity? {
        guard sessionID.hasPrefix("terminal:") else { return nil }
        let body = String(sessionID.dropFirst("terminal:".count))
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let application = TerminalApplicationKind.detect(bundleIdentifier: String(parts[0]), terminalProgram: String(parts[0]))
        let resourceAndQuery = String(parts[1])
        let resourceParts = resourceAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let resource = decode(String(resourceParts[0]))
        var values: [String: String] = [:]
        if resourceParts.count == 2 {
            for pair in resourceParts[1].split(separator: "&", omittingEmptySubsequences: true) {
                let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2 else { continue }
                values[decode(String(fields[0]))] = decode(String(fields[1]))
            }
        }

        var multiplexer: TerminalMultiplexerKind?
        var nativeSessionID: String?
        var tty: String?
        var weztermPane: String?
        var kittyWindowID: String?
        var tmuxPane: String?
        var zellijPaneID: String?
        if resource.hasPrefix("tmux:") {
            multiplexer = .tmux
            tmuxPane = String(resource.dropFirst("tmux:".count))
            if tmuxPane == "unknown" { tmuxPane = nil }
        } else if resource.hasPrefix("zellij:") {
            multiplexer = .zellij
            zellijPaneID = String(resource.dropFirst("zellij:".count))
            if zellijPaneID == "unknown" { zellijPaneID = nil }
        } else if resource.hasPrefix("session:") {
            nativeSessionID = decode(String(resource.dropFirst("session:".count)))
        } else if resource.hasPrefix("pane:") {
            weztermPane = decode(String(resource.dropFirst("pane:".count)))
        } else if resource.hasPrefix("window:") {
            kittyWindowID = decode(String(resource.dropFirst("window:".count)))
        } else if resource.hasPrefix("tty:") {
            tty = decode(String(resource.dropFirst("tty:".count)))
        } else if resource.hasPrefix("pid-") {
            values["pid"] = String(resource.dropFirst("pid-".count))
        } else if !resource.isEmpty, resource != "unknown" {
            // Compatibility with the earlier terminal:<program>:<tty> format.
            tty = resource
        }

        let processID = values["pid"].flatMap(Int32.init)
        let tmux = values["tmux"]
        if multiplexer == nil, values["mux"] == TerminalMultiplexerKind.tmux.rawValue {
            multiplexer = .tmux
        } else if multiplexer == nil, values["mux"] == TerminalMultiplexerKind.zellij.rawValue {
            multiplexer = .zellij
        }
        return TerminalIdentity(
            application: application,
            multiplexer: multiplexer,
            nativeSessionID: nativeSessionID,
            terminalProgram: values["program"],
            tty: tty ?? values["tty"],
            processID: processID,
            bundleIdentifier: values["bundle"],
            weztermPane: weztermPane,
            weztermUnixSocket: application == .wezterm ? values["socket"] : nil,
            kittyWindowID: kittyWindowID,
            kittyRemoteSocket: application == .kitty ? values["socket"] : nil,
            tmux: tmux,
            tmuxSocket: values["tmuxSocket"] ?? tmux?.split(separator: ",", maxSplits: 1).first.map(String.init),
            tmuxPane: tmuxPane,
            zellijSessionName: values["session"],
            zellijPaneID: zellijPaneID,
            sshTTY: values["sshTTY"],
            sshConnection: values["sshConnection"],
            remoteHost: values["remoteHost"]
        )
    }

    private static func encode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
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

public enum NativeSessionTransport: String, Codable, CaseIterable, Sendable {
    case codexAppServer
    case acp
    case openCodeServer
}

/// A provider conversation that Noturcode controls through a native protocol.
/// It is separate from TerminalTarget because a native session can exist with
/// no terminal window, tab, TTY, or pane.
public struct NativeSessionConnection: Codable, Equatable, Sendable {
    public var transport: NativeSessionTransport
    public var conversationID: String
    public var endpoint: String?

    public init(
        transport: NativeSessionTransport,
        conversationID: String,
        endpoint: String? = nil
    ) {
        self.transport = transport
        self.conversationID = conversationID
        self.endpoint = endpoint
    }
}

public struct TrackedSession: Identifiable, Codable, Equatable, Sendable {
    public var key: SessionKey
    public var name: String
    public var terminal: TerminalTarget?
    public var nativeSession: NativeSessionConnection?
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
        terminal: TerminalTarget? = nil,
        nativeSession: NativeSessionConnection? = nil,
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
        self.nativeSession = nativeSession
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
        subagents.filter {
            ($0.state == .working || $0.state == .askingYou)
                && $0.updatedAt >= lastPromptAt
        }
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

public struct TerminalImagePasteRequest: Codable, Equatable, Sendable {
    public let type: String
    public let terminalSessionID: String

    public init(terminalSessionID: String) {
        type = "terminalImagePaste"
        self.terminalSessionID = terminalSessionID
    }
}

public struct TerminalImagePasteSessionsRequest: Codable, Equatable, Sendable {
    public let type: String

    public init() {
        type = "terminalImagePasteSessions"
    }
}

public struct TerminalImagePasteSessionsResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let sessionIDs: [String]

    public init(ok: Bool, sessionIDs: [String]) {
        self.ok = ok
        self.sessionIDs = sessionIDs
    }
}

public struct BridgeEvent: Codable, Equatable, Sendable {
    public var kind: BridgeEventKind
    public var source: AgentSource
    public var sessionID: String
    public var timestamp: Date
    public var name: String?
    public var terminalSessionID: String?
    public var nativeSession: NativeSessionConnection?
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
        nativeSession: NativeSessionConnection? = nil,
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
        self.nativeSession = nativeSession
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
