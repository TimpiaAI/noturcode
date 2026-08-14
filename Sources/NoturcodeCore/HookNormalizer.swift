import Foundation

public enum NCCommand: Equatable, Sendable {
    case connect(String)
    case stop
    case invalid(String)

    public static func parse(prompt: String) -> NCCommand? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexExpansionPrefix = "NOTURCODE_CONNECT"
        if trimmed == codexExpansionPrefix || trimmed.hasPrefix(codexExpansionPrefix + " ") || trimmed.hasPrefix(codexExpansionPrefix + "\n") {
            let remainder = String(trimmed.dropFirst(codexExpansionPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else {
                return .invalid("Type /nc followed by a session name.")
            }
            if remainder.lowercased() == "stop" { return .stop }
            return .connect(remainder)
        }
        if trimmed.caseInsensitiveCompare("nc") == .orderedSame
            || trimmed.lowercased().hasPrefix("nc ")
            || trimmed.lowercased().hasPrefix("nc\t") {
            let remainder = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else {
                return .invalid("Type nc followed by a session name.")
            }
            if remainder.lowercased() == "stop" { return .stop }
            return .connect(remainder)
        }
        guard trimmed == "/nc" || trimmed.hasPrefix("/nc ") || trimmed.hasPrefix("/nc\t") else {
            return nil
        }
        let remainder = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return .invalid("Type /nc followed by a session name.")
        }
        if remainder.lowercased() == "stop" { return .stop }
        return .connect(remainder)
    }

    public static func parse(commandName: String, arguments: String) -> NCCommand? {
        guard commandName.lowercased() == "nc" else { return nil }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid("Type /nc followed by a session name.")
        }
        if trimmed.lowercased() == "stop" { return .stop }
        return .connect(trimmed)
    }
}

public struct HookCommandResult: Equatable, Sendable {
    public var message: String
    public var shouldBlockPrompt: Bool

    public init(message: String, shouldBlockPrompt: Bool = true) {
        self.message = message
        self.shouldBlockPrompt = shouldBlockPrompt
    }
}

public struct HookNormalizationResult: Equatable, Sendable {
    public var events: [BridgeEvent]
    public var commandResult: HookCommandResult?

    public init(events: [BridgeEvent], commandResult: HookCommandResult? = nil) {
        self.events = events
        self.commandResult = commandResult
    }
}

public enum HookNormalizer {
    public static func normalize(
        payload data: Data,
        source: AgentSource,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourceProcessID: Int32? = nil,
        terminalSessionIDOverride: String? = nil,
        now: Date = Date()
    ) throws -> HookNormalizationResult {
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        return normalize(
            payload: payload,
            source: source,
            environment: environment,
            sourceProcessID: sourceProcessID,
            terminalSessionIDOverride: terminalSessionIDOverride,
            now: now
        )
    }

    public static func normalize(
        payload: JSONValue,
        source: AgentSource,
        environment: [String: String],
        sourceProcessID: Int32?,
        terminalSessionIDOverride: String? = nil,
        now: Date
    ) -> HookNormalizationResult {
        let eventName = payload.firstString(for: ["hook_event_name", "hookEventName", "type"]) ?? ""
        let sessionID = payload.firstString(for: ["session_id", "sessionId", "thread_id", "threadId"])
            ?? environment["CODEX_THREAD_ID"]
            ?? environment["CLAUDE_SESSION_ID"]
            ?? "unknown-\(sourceProcessID ?? 0)"
        let terminalSessionID = terminalSessionIDOverride
            ?? terminalIdentity(environment: environment, sourceProcessID: sourceProcessID)
        let cwd = payload.firstString(for: ["cwd"]) ?? environment["PWD"]
        let transcriptPath = payload.firstString(for: ["transcript_path", "transcriptPath", "rollout_path", "rolloutPath"])
        let tokens = payload.recursivelySummedTokens()
        let agentID = payload.firstString(for: ["agent_id", "agentId"])
        let agentType = payload.firstString(for: ["agent_type", "agentType"]) ?? "agent"

        func event(
            _ kind: BridgeEventKind,
            message: String? = nil,
            activity: String? = nil,
            error: String? = nil,
            subagentID: String? = nil,
            subagentType: String? = nil
        ) -> BridgeEvent {
            BridgeEvent(
                kind: kind,
                source: source,
                sessionID: sessionID,
                timestamp: now,
                terminalSessionID: terminalSessionID,
                sourceProcessID: sourceProcessID,
                cwd: cwd,
                transcriptPath: transcriptPath,
                message: message,
                activity: activity,
                error: error,
                subagentID: subagentID,
                subagentType: subagentType,
                tokens: tokens
            )
        }

        if eventName.caseInsensitiveCompare("UserPromptExpansion") == .orderedSame {
            let commandName = payload.firstString(for: ["command_name", "commandName"]) ?? ""
            let arguments = payload.firstString(for: ["command_args", "commandArgs"]) ?? ""
            if let command = NCCommand.parse(commandName: commandName, arguments: arguments) {
                return normalizeCommand(
                    command,
                    source: source,
                    sessionID: sessionID,
                    terminalSessionID: terminalSessionID,
                    sourceProcessID: sourceProcessID,
                    cwd: cwd,
                    transcriptPath: transcriptPath,
                    now: now
                )
            }
        }

        if eventName.caseInsensitiveCompare("UserPromptSubmit") == .orderedSame {
            let prompt = payload.firstString(for: ["prompt"]) ?? ""
            if let command = NCCommand.parse(prompt: prompt) {
                return normalizeCommand(
                    command,
                    source: source,
                    sessionID: sessionID,
                    terminalSessionID: terminalSessionID,
                    sourceProcessID: sourceProcessID,
                    cwd: cwd,
                    transcriptPath: transcriptPath,
                    now: now
                )
            }
            var submitted = event(.promptSubmitted)
            submitted.prompt = prompt
            return HookNormalizationResult(events: [submitted])
        }

        if eventName.caseInsensitiveCompare("BeforeAgent") == .orderedSame {
            let prompt = payload.firstString(for: ["prompt", "user_prompt", "userPrompt"]) ?? ""
            if let command = NCCommand.parse(prompt: prompt) {
                return normalizeCommand(
                    command,
                    source: source,
                    sessionID: sessionID,
                    terminalSessionID: terminalSessionID,
                    sourceProcessID: sourceProcessID,
                    cwd: cwd,
                    transcriptPath: transcriptPath,
                    now: now
                )
            }
            var submitted = event(.promptSubmitted)
            submitted.prompt = prompt
            return HookNormalizationResult(events: [submitted])
        }

        switch eventName.lowercased() {
        case "sessionstart":
            return HookNormalizationResult(events: [event(.sessionStarted)])

        case "sessionend":
            return HookNormalizationResult(events: [event(.sessionEnded)])

        case "pretooluse", "beforetool":
            let toolName = payload.firstString(for: ["tool_name", "toolName"]) ?? "tool"
            if isExplicitQuestionTool(toolName) {
                return HookNormalizationResult(events: [event(.askingYou, activity: "waiting on your answer")])
            }
            let activity = activityDescription(for: toolName, payload: payload)
            if let agentID {
                return HookNormalizationResult(events: [event(
                    .subagentActivity,
                    activity: activity,
                    subagentID: agentID,
                    subagentType: agentType
                )])
            }
            return HookNormalizationResult(events: [event(.activityStarted, activity: activity)])

        case "posttooluse", "posttoolusefailure", "posttoolbatch", "aftertool", "aftertoolfailure":
            let toolName = payload.firstString(for: ["tool_name", "toolName"]) ?? "tool"
            let toolActivity = activityDescription(for: toolName, payload: payload)
            let activity = eventName.lowercased().contains("failure")
                ? "Failed · \(toolActivity)"
                : "Finished · \(toolActivity)"
            if let agentID {
                return HookNormalizationResult(events: [event(
                    .subagentActivity,
                    activity: activity,
                    subagentID: agentID,
                    subagentType: agentType
                )])
            }
            return HookNormalizationResult(events: [event(.activityFinished, activity: activity)])

        case "stop", "afteragent":
            let message = payload.firstString(for: ["last_assistant_message", "lastAssistantMessage", "prompt_response", "response"])
            return HookNormalizationResult(events: [event(.responseCompleted, message: message)])

        case "stopfailure", "afteragentfailure":
            let error = payload.firstString(for: ["error_details", "last_assistant_message", "error"])
            return HookNormalizationResult(events: [event(.failed, error: error ?? "The agent reported a failure.")])

        case "notification":
            let notificationType = payload.firstString(for: ["notification_type", "notificationType"]) ?? ""
            let message = payload.firstString(for: ["message"])
            if notificationType == "agent_needs_input" {
                return HookNormalizationResult(events: [event(.askingYou, message: message, activity: "waiting on your answer")])
            }
            if notificationType == "agent_completed" {
                return HookNormalizationResult(events: [event(.responseCompleted, message: message)])
            }
            return HookNormalizationResult(events: [])

        case "subagentstart":
            guard let agentID else { return HookNormalizationResult(events: []) }
            return HookNormalizationResult(events: [event(
                .subagentStarted,
                activity: "working",
                subagentID: agentID,
                subagentType: agentType
            )])

        case "subagentstop":
            guard let agentID else { return HookNormalizationResult(events: []) }
            let message = payload.firstString(for: ["last_assistant_message", "lastAssistantMessage"])
            return HookNormalizationResult(events: [event(
                .subagentCompleted,
                message: message,
                subagentID: agentID,
                subagentType: agentType
            )])

        default:
            return HookNormalizationResult(events: [])
        }
    }

    private static func normalizeCommand(
        _ command: NCCommand,
        source: AgentSource,
        sessionID: String,
        terminalSessionID: String?,
        sourceProcessID: Int32?,
        cwd: String?,
        transcriptPath: String?,
        now: Date
    ) -> HookNormalizationResult {
        switch command {
        case let .connect(name):
            guard let terminalSessionID, !terminalSessionID.isEmpty else {
                return HookNormalizationResult(events: [], commandResult: HookCommandResult(
                    message: "Noturcode could not identify this terminal. Start the CLI from a normal terminal window and retry."
                ))
            }
            let event = BridgeEvent(
                kind: .connect,
                source: source,
                sessionID: sessionID,
                timestamp: now,
                name: name,
                terminalSessionID: terminalSessionID,
                sourceProcessID: sourceProcessID,
                cwd: cwd,
                transcriptPath: transcriptPath
            )
            return HookNormalizationResult(
                events: [event],
                commandResult: HookCommandResult(message: "Noturcode connected \"\(name)\".")
            )

        case .stop:
            let event = BridgeEvent(kind: .disconnect, source: source, sessionID: sessionID, timestamp: now)
            return HookNormalizationResult(
                events: [event],
                commandResult: HookCommandResult(message: "Noturcode disconnected this session.")
            )

        case let .invalid(message):
            return HookNormalizationResult(events: [], commandResult: HookCommandResult(message: message))
        }
    }

    private static func isExplicitQuestionTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("askuserquestion")
            || normalized.contains("request_user_input")
            || normalized.contains("requestuserinput")
            || normalized.contains("elicitation")
    }

    public static func terminalIdentity(environment: [String: String], sourceProcessID: Int32?) -> String? {
        TerminalIdentity.capture(environment: environment, sourceProcessID: sourceProcessID)?.sessionID
    }

    public static func activityDescription(for toolName: String, payload: JSONValue? = nil) -> String {
        let displayName = toolDisplayName(toolName)
        if let detail = payload.flatMap({ toolDetail(for: toolName, payload: $0) }) {
            return "\(displayName) · \(detail)"
        }

        let normalized = toolName.lowercased()
        if normalized.contains("read") || normalized.contains("view_image") || normalized.contains("open") {
            return displayName
        }
        if normalized.contains("write") || normalized.contains("edit") || normalized.contains("patch") {
            return displayName
        }
        if normalized.contains("bash") || normalized.contains("shell") || normalized.contains("exec") || normalized.contains("command") {
            return displayName
        }
        if normalized.contains("search") || normalized.contains("web") || normalized.contains("firecrawl") {
            return displayName
        }
        if normalized.contains("agent") || normalized.contains("task") {
            return displayName
        }
        return displayName
    }

    private static func toolDisplayName(_ toolName: String) -> String {
        let leaf = toolName.split(separator: ".").last.map(String.init) ?? toolName
        let normalized = leaf.lowercased()
        if normalized == "exec_command" || normalized == "execute" { return "Command" }
        if normalized == "apply_patch" { return "Edit" }
        if normalized == "view_image" { return "Image" }
        if normalized == "request_user_input" { return "Question" }
        return leaf.isEmpty ? "Tool" : leaf
    }

    private static func toolDetail(for toolName: String, payload: JSONValue) -> String? {
        let normalized = toolName.lowercased()
        let inputKeys = ["tool_input", "toolInput", "input", "arguments"]

        func paths(_ keys: [String]) -> [[String]] {
            inputKeys.flatMap { inputKey in keys.map { [inputKey, $0] } }
        }

        let candidate: String?
        if normalized.contains("bash") || normalized.contains("shell") || normalized.contains("exec") || normalized.contains("command") {
            candidate = payload.firstString(at: paths(["command", "cmd", "script"]))
        } else if normalized.contains("read") || normalized.contains("write") || normalized.contains("edit") || normalized.contains("patch") || normalized.contains("image") {
            candidate = payload.firstString(at: paths(["file_path", "path", "file", "target"]))
        } else if normalized.contains("search") || normalized.contains("grep") || normalized.contains("glob") || normalized.contains("find") {
            candidate = payload.firstString(at: paths(["query", "pattern", "q", "search_term"]))
        } else if normalized.contains("web") || normalized.contains("fetch") || normalized.contains("open") {
            candidate = payload.firstString(at: paths(["url", "query", "q", "ref_id"]))
        } else if normalized.contains("agent") || normalized.contains("task") {
            candidate = payload.firstString(at: paths(["description", "task", "prompt", "message"]))
        } else {
            candidate = payload.firstString(at: paths(["command", "file_path", "path", "query", "url", "description"]))
        }
        guard let candidate else { return nil }
        return safeToolDetail(candidate)
    }

    private static func safeToolDetail(_ raw: String) -> String? {
        let compact = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !compact.isEmpty else { return nil }

        let sensitiveMarkers = [
            "password", "passwd", "secret", "api_key", "apikey", "access_token",
            "auth_token", "authorization:", "bearer ", "private_key", "client_secret"
        ]
        if sensitiveMarkers.contains(where: { compact.lowercased().contains($0) }) {
            return "sensitive arguments hidden"
        }

        let limit = 150
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 1)) + "…"
    }
}
