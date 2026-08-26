import Foundation

/// The only OpenCode endpoint that this client will use is an explicitly configured
/// local server. It never searches for, starts, or attaches to a server by port.
public struct OpenCodeServerConfiguration: Equatable, Sendable {
    public static let urlEnvironmentKey = "NOTURCODE_OPENCODE_URL"

    public let baseURL: URL
    public let username: String?
    public let password: String?
    public let directory: String?

    public init(
        baseURL: URL,
        username: String? = nil,
        password: String? = nil,
        directory: String? = nil
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = baseURL.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              baseURL.port != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil
        else {
            throw OpenCodeNativeClientError.invalidConfiguration(
                "OpenCode URL must be an explicit localhost URL with a port"
            )
        }

        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.directory = directory
    }

    /// Reads one explicit URL. An absent variable means that OpenCode is disabled.
    /// It does not fall back to a default port and does not scan local ports.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> OpenCodeServerConfiguration? {
        guard let rawURL = environment[urlEnvironmentKey], !rawURL.isEmpty else {
            return nil
        }

        guard let url = URL(string: rawURL) else {
            throw OpenCodeNativeClientError.invalidConfiguration("OpenCode URL is not valid")
        }

        return try OpenCodeServerConfiguration(
            baseURL: url,
            username: environment["OPENCODE_SERVER_USERNAME"],
            password: environment["OPENCODE_SERVER_PASSWORD"],
            directory: environment["NOTURCODE_OPENCODE_DIRECTORY"]
        )
    }
}

public enum OpenCodeNativeClientError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidSessionID
    case invalidPermissionID
    case emptyPrompt
    case httpStatus(Int)
    case invalidResponse(String)
    case streamEnded
    case alreadyRunning
}

extension OpenCodeNativeClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .invalidSessionID: return "OpenCode session ID is empty"
        case .invalidPermissionID: return "OpenCode permission ID is empty"
        case .emptyPrompt: return "OpenCode prompt is empty"
        case .httpStatus(let status): return "OpenCode server returned HTTP \(status)"
        case .invalidResponse(let message): return message
        case .streamEnded: return "OpenCode event stream ended"
        case .alreadyRunning: return "OpenCode native client is already running"
        }
    }
}

public struct OpenCodeReconnectPolicy: Equatable, Sendable {
    public let delaysNanoseconds: [UInt64]

    public init(delaysNanoseconds: [UInt64] = [
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000
    ]) {
        self.delaysNanoseconds = delaysNanoseconds.isEmpty ? [8_000_000_000] : delaysNanoseconds
    }

    public func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let index = max(0, min(attempt - 1, delaysNanoseconds.count - 1))
        return delaysNanoseconds[index]
    }
}

public struct OpenCodeSSEEvent: Equatable, Sendable {
    public let id: String?
    public let event: String?
    public let data: String

    public init(id: String? = nil, event: String? = nil, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

/// Small, dependency-free SSE parser. It accepts both URLSession line output and
/// raw byte chunks, and it keeps the server-provided event ID for reconnects.
public struct OpenCodeSSEParser: Sendable {
    private var buffer = Data()
    private var currentEventID: String?
    private var currentEventName: String?
    private var currentDataLines: [String] = []

    public private(set) var lastEventID: String?

    public init() {}

    public mutating func append(_ data: Data) -> [OpenCodeSSEEvent] {
        buffer.append(data)
        var events: [OpenCodeSSEEvent] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.last == "\r" {
                line.removeLast()
            }
            events.append(contentsOf: consume(line: line))
        }

        return events
    }

    public mutating func appendLine(_ line: String) -> [OpenCodeSSEEvent] {
        consume(line: line.hasSuffix("\r") ? String(line.dropLast()) : line)
    }

    public mutating func finish() -> [OpenCodeSSEEvent] {
        var events: [OpenCodeSSEEvent] = []
        if !buffer.isEmpty {
            events.append(contentsOf: append(Data([0x0A])))
        }
        if !currentDataLines.isEmpty || currentEventName != nil {
            events.append(contentsOf: dispatch())
        }
        return events
    }

    private mutating func consume(line: String) -> [OpenCodeSSEEvent] {
        if line.isEmpty {
            return dispatchIfNeeded()
        }

        if line.hasPrefix(":") {
            return []
        }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.first == " " {
                value.removeFirst()
            }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "id":
            if !value.contains("\0") {
                currentEventID = value
                lastEventID = value
            }
        case "event":
            currentEventName = value
        case "data":
            currentDataLines.append(value)
        default:
            break
        }

        return []
    }

    private mutating func dispatchIfNeeded() -> [OpenCodeSSEEvent] {
        guard !currentDataLines.isEmpty || currentEventName != nil else {
            currentEventID = nil
            return []
        }
        return dispatch()
    }

    private mutating func dispatch() -> [OpenCodeSSEEvent] {
        let event = OpenCodeSSEEvent(
            id: currentEventID,
            event: currentEventName,
            data: currentDataLines.joined(separator: "\n")
        )
        currentEventID = nil
        currentEventName = nil
        currentDataLines.removeAll(keepingCapacity: true)
        return [event]
    }
}

public enum OpenCodePermissionReply: String, Codable, CaseIterable, Sendable {
    case once
    case always
    case reject
}

public struct OpenCodeSession: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let directory: String?
    public let parentID: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: String,
        title: String? = nil,
        directory: String? = nil,
        parentID: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.parentID = parentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct OpenCodeSessionStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case idle
        case busy
        case retry
        case unknown
    }

    public let state: State
    public let message: String?
    public let attempt: Int?

    public init(state: State, message: String? = nil, attempt: Int? = nil) {
        self.state = state
        self.message = message
        self.attempt = attempt
    }
}

public struct OpenCodePermissionRequest: Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let type: String?
    public let pattern: [String]
    public let title: String?
    public let messageID: String?

    public init(
        id: String,
        sessionID: String,
        type: String? = nil,
        pattern: [String] = [],
        title: String? = nil,
        messageID: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.type = type
        self.pattern = pattern
        self.title = title
        self.messageID = messageID
    }
}

public struct OpenCodeReconciliation: Equatable, Sendable {
    public let sessions: [OpenCodeSession]
    public let subagents: [OpenCodeSession]
    public let statuses: [String: OpenCodeSessionStatus]
    public let messages: [String: [ChatTranscriptEntry]]
    public let permissions: [OpenCodePermissionRequest]

    public init(
        sessions: [OpenCodeSession],
        subagents: [OpenCodeSession] = [],
        statuses: [String: OpenCodeSessionStatus],
        messages: [String: [ChatTranscriptEntry]],
        permissions: [OpenCodePermissionRequest] = []
    ) {
        self.sessions = sessions
        self.subagents = subagents
        self.statuses = statuses
        self.messages = messages
        self.permissions = permissions
    }
}

public struct OpenCodeEventSessionContext: Equatable, Sendable {
    public let type: String
    public let sessionID: String
    public let parentID: String?

    public init(type: String, sessionID: String, parentID: String?) {
        self.type = type
        self.sessionID = sessionID
        self.parentID = parentID
    }
}

public enum OpenCodeNativeEventMapper {
    public static func bridgeEvents(
        for event: OpenCodeSSEEvent,
        now: Date = Date(),
        sessionScope: Set<String> = [],
        nativeEndpoint: String? = nil,
        knownParentID: String? = nil
    ) -> [BridgeEvent] {
        guard let envelope = jsonObject(from: event.data),
              let (type, object) = eventTypeAndPayload(event: event, envelope: envelope),
              let sessionID = sessionID(from: object)
        else {
            return []
        }

        let info = object["info"] as? [String: Any]
        let parentID = knownParentID
            ?? string(object["parentID"])
            ?? string(object["parentId"])
            ?? string(object["parent_id"])
            ?? string(info?["parentID"])
            ?? string(info?["parentId"])
            ?? string(info?["parent_id"])
        guard sessionScope.isEmpty || sessionScope.contains(parentID ?? sessionID) else { return [] }
        let sessionName = string(object["title"])
            ?? string(object["name"])
            ?? string(info?["title"])
        let directory = string(object["directory"]) ?? string(info?["directory"])
        if let parentID {
            return childBridgeEvents(
                type: type,
                childSessionID: sessionID,
                parentSessionID: parentID,
                object: object,
                now: now,
                name: sessionName
            )
        }

        switch type {
        case "session.created", "session.updated":
            return [BridgeEvent(
                kind: .connect,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                name: sessionName,
                nativeSession: NativeSessionConnection(
                    transport: .openCodeServer,
                    conversationID: sessionID,
                    endpoint: nativeEndpoint
                ),
                cwd: directory
            )]
        case "session.deleted":
            return [BridgeEvent(
                kind: .disconnect,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                name: sessionName,
                cwd: directory
            )]
        case "session.idle":
            return [BridgeEvent(
                kind: .turnInterrupted,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                name: sessionName,
                cwd: directory,
                message: string(object["message"])
            )]
        case "session.error":
            return [BridgeEvent(
                kind: .failed,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                name: sessionName,
                cwd: directory,
                error: string(object["error"]) ?? string(object["message"]) ?? "OpenCode session error"
            )]
        case "session.status":
            return statusBridgeEvents(
                sessionID: sessionID,
                object: object,
                now: now,
                name: sessionName,
                directory: directory
            )
        case "session.next.model.switched", "message.updated":
            let modelObject = (object["model"] as? [String: Any])
                ?? (info?["model"] as? [String: Any])
            let provider = string(modelObject?["providerID"])
                ?? string(object["providerID"])
                ?? string(info?["providerID"])
            let model = string(modelObject?["modelID"])
                ?? string(object["modelID"])
                ?? string(info?["modelID"])
            let agent = string(object["agent"]) ?? string(info?["agent"])
            guard provider != nil || model != nil || agent != nil else { return [] }
            return [BridgeEvent(
                kind: .metadataUpdated,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                provider: provider,
                model: model,
                agentRole: agent
            )]
        case "session.next.agent.switched":
            guard let agent = string(object["agent"]) ?? string(info?["agent"]) else { return [] }
            return [BridgeEvent(
                kind: .metadataUpdated,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                agentRole: agent
            )]
        case "permission.updated":
            return [BridgeEvent(
                kind: .askingYou,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                name: sessionName,
                cwd: directory,
                activity: string(object["title"]) ?? string(object["type"]) ?? "permission"
            )]
        case "message.part.updated":
            return toolBridgeEvents(
                sessionID: sessionID,
                object: object,
                now: now,
                name: sessionName,
                directory: directory
            )
        default:
            return []
        }
    }

    public static func sessionContext(from event: OpenCodeSSEEvent) -> OpenCodeEventSessionContext? {
        guard let envelope = jsonObject(from: event.data),
              let (type, object) = eventTypeAndPayload(event: event, envelope: envelope),
              let sessionID = sessionID(from: object) else { return nil }
        let info = object["info"] as? [String: Any]
        let parentID = string(object["parentID"])
            ?? string(object["parentId"])
            ?? string(object["parent_id"])
            ?? string(info?["parentID"])
            ?? string(info?["parentId"])
            ?? string(info?["parent_id"])
        return OpenCodeEventSessionContext(type: type, sessionID: sessionID, parentID: parentID)
    }

    private static func childBridgeEvents(
        type: String,
        childSessionID: String,
        parentSessionID: String,
        object: [String: Any],
        now: Date,
        name: String?
    ) -> [BridgeEvent] {
        let agentType = name
            ?? string(object["agent"])
            ?? string((object["info"] as? [String: Any])?["agent"])
            ?? "OpenCode agent"
        let status = (object["status"] as? [String: Any]) ?? object
        let state = string(status["type"]) ?? string(status["status"])
        let kind: BridgeEventKind
        let activity: String?
        switch type {
        case "session.created":
            kind = .subagentStarted
            activity = "starting"
        case "session.updated", "message.part.updated":
            kind = .subagentActivity
            activity = string((object["part"] as? [String: Any])?["tool"]) ?? "working"
        case "session.idle", "session.deleted":
            kind = .subagentCompleted
            activity = nil
        case "session.error":
            kind = .subagentFailed
            activity = nil
        case "session.status":
            if state == "idle" || state == "done" || state == "completed" {
                kind = .subagentCompleted
                activity = nil
            } else {
                kind = .subagentActivity
                activity = string(status["message"]) ?? state ?? "working"
            }
        default:
            return []
        }
        return [BridgeEvent(
            kind: kind,
            source: .opencode,
            sessionID: parentSessionID,
            timestamp: now,
            message: kind == .subagentCompleted ? string(object["message"]) : nil,
            activity: activity,
            error: kind == .subagentFailed
                ? string(object["error"]) ?? string(object["message"]) ?? "OpenCode agent failed"
                : nil,
            subagentID: childSessionID,
            subagentType: agentType
        )]
    }

    public static func permissionRequest(
        from event: OpenCodeSSEEvent
    ) -> OpenCodePermissionRequest? {
        guard let envelope = jsonObject(from: event.data),
              let (type, object) = eventTypeAndPayload(event: event, envelope: envelope),
              type == "permission.updated",
              let id = string(object["id"]),
              let sessionID = sessionID(from: object)
        else {
            return nil
        }
        return permission(from: object, id: id, sessionID: sessionID)
    }

    public static func chatEntry(
        from event: OpenCodeSSEEvent
    ) -> (sessionID: String, entry: ChatTranscriptEntry)? {
        guard let envelope = jsonObject(from: event.data),
              let (type, object) = eventTypeAndPayload(event: event, envelope: envelope),
              type == "message.part.updated",
              let sessionID = sessionID(from: object),
              let part = object["part"] as? [String: Any]
        else {
            return nil
        }

        let partType = string(part["type"])
        let partID = string(part["id"]) ?? UUID().uuidString
        let messageID = string(part["messageID"]) ?? partID
        let timestamp = date(from: part["time"])

        if partType == "text", let text = string(part["text"]), !text.isEmpty {
            return (
                sessionID,
                ChatTranscriptEntry(
                    id: partID,
                    kind: .assistant,
                    title: nil,
                    text: text,
                    detail: nil,
                    timestamp: timestamp,
                    imagePaths: [],
                    model: nil
                )
            )
        }

        guard partType == "tool", let tool = string(part["tool"]) else {
            return nil
        }

        let state = part["state"] as? [String: Any]
        let status = string(state?["status"]) ?? "pending"
        let detail = string(state?["output"]) ?? string(state?["error"])
        let input = prettyJSON(state?["input"])
        let text = input ?? detail ?? status
        return (
            sessionID,
            ChatTranscriptEntry(
                id: "\(messageID):\(partID)",
                kind: .tool,
                title: tool,
                text: text,
                detail: detail,
                timestamp: timestamp,
                imagePaths: [],
                model: nil
            )
        )
    }

    fileprivate static func latestAssistantMessage(
        in entries: [ChatTranscriptEntry]
    ) -> String? {
        entries.last(where: { $0.kind == .assistant && !$0.text.isEmpty })?.text
    }

    private static func statusBridgeEvents(
        sessionID: String,
        object: [String: Any],
        now: Date,
        name: String?,
        directory: String?
    ) -> [BridgeEvent] {
        let status = (object["status"] as? [String: Any]) ?? object
        let state = string(status["type"]) ?? string(status["status"])
        switch state {
        case "busy":
            return [BridgeEvent(
                kind: .activityStarted,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                name: name,
                cwd: directory,
                activity: "working"
            )]
        case "retry":
            let message = string(status["message"]) ?? "retrying"
            return [BridgeEvent(
                kind: .activityStarted,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                name: name,
                cwd: directory,
                activity: message
            )]
        case "idle":
            return [BridgeEvent(
                kind: .turnInterrupted,
                source: .opencode,
                sessionID: sessionID,
                timestamp: now,
                name: name,
                cwd: directory
            )]
        default:
            return []
        }
    }

    private static func toolBridgeEvents(
        sessionID: String,
        object: [String: Any],
        now: Date,
        name: String?,
        directory: String?
    ) -> [BridgeEvent] {
        guard let part = object["part"] as? [String: Any],
              string(part["type"]) == "tool"
        else {
            return []
        }
        let tool = string(part["tool"]) ?? "tool"
        let state = part["state"] as? [String: Any]
        let status = string(state?["status"]) ?? "pending"
        let kind: BridgeEventKind
        let activity: String
        switch status {
        case "completed":
            kind = .activityFinished
            activity = "finished · \(tool)"
        case "error":
            kind = .failed
            activity = "failed · \(tool)"
        default:
            kind = .activityStarted
            activity = "\(status) · \(tool)"
        }
        return [BridgeEvent(
            kind: kind,
            source: .opencode,
            sessionID: sessionID,
            timestamp: now,
            name: name,
            cwd: directory,
            activity: activity,
            error: kind == .failed ? string(state?["error"]) : nil
        )]
    }

    private static func sessionID(from object: [String: Any]) -> String? {
        if let sessionID = string(object["sessionID"]) {
            return sessionID
        }
        if let info = object["info"] as? [String: Any] {
            return string(info["sessionID"]) ?? string(info["id"])
        }
        if let part = object["part"] as? [String: Any] {
            return string(part["sessionID"])
        }
        return nil
    }

    private static func eventTypeAndPayload(
        event: OpenCodeSSEEvent,
        envelope: [String: Any]
    ) -> (String, [String: Any])? {
        let envelopeType = string(envelope["type"])
        let type = envelopeType ?? (event.event == "message" ? nil : event.event)
        guard let type else { return nil }
        let payload = envelope["properties"] as? [String: Any] ?? envelope
        return (type, payload)
    }

    private static func permission(
        from object: [String: Any],
        id: String,
        sessionID: String
    ) -> OpenCodePermissionRequest {
        OpenCodePermissionRequest(
            id: id,
            sessionID: sessionID,
            type: string(object["type"]),
            pattern: (object["pattern"] as? [String]) ?? [],
            title: string(object["title"]),
            messageID: string(object["messageID"])
        )
    }

    fileprivate static func jsonObject(from data: String) -> [String: Any]? {
        guard let bytes = data.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: bytes),
              let object = value as? [String: Any]
        else {
            return nil
        }
        return object
    }

    fileprivate static func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    fileprivate static func date(from value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let seconds = number.doubleValue > 10_000_000_000
            ? number.doubleValue / 1_000
            : number.doubleValue
        return Date(timeIntervalSince1970: seconds)
    }

    fileprivate static func qualifiedModel(provider: String?, model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        guard let provider, !provider.isEmpty, !model.hasPrefix(provider + "/") else { return model }
        return "\(provider)/\(model)"
    }

    fileprivate static func prettyJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }
}

public actor OpenCodeNativeClient {
    public typealias BridgeEventHandler = @Sendable (BridgeEvent) async -> Void
    public typealias ChatHandler = @Sendable (String, [ChatTranscriptEntry]) async -> Void
    public typealias PermissionHandler = @Sendable (OpenCodePermissionRequest) async -> Void

    private let configuration: OpenCodeServerConfiguration
    private let urlSession: URLSession
    private let eventHandler: BridgeEventHandler
    private let chatHandler: ChatHandler
    private let permissionHandler: PermissionHandler
    private let reconnectPolicy: OpenCodeReconnectPolicy

    private var streamTask: Task<Void, Never>?
    private var lastEventID: String?
    private var watchedSessionIDs: Set<String> = []
    private var childParentIDs: [String: String] = [:]

    public init(
        configuration: OpenCodeServerConfiguration,
        urlSession: URLSession = .shared,
        eventHandler: @escaping BridgeEventHandler = { _ in },
        chatHandler: @escaping ChatHandler = { _, _ in },
        permissionHandler: @escaping PermissionHandler = { _ in },
        reconnectPolicy: OpenCodeReconnectPolicy = OpenCodeReconnectPolicy()
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.eventHandler = eventHandler
        self.chatHandler = chatHandler
        self.permissionHandler = permissionHandler
        self.reconnectPolicy = reconnectPolicy
    }

    public var isRunning: Bool { streamTask != nil }

    public func start(sessionIDs: Set<String> = []) async throws {
        guard streamTask == nil else {
            throw OpenCodeNativeClientError.alreadyRunning
        }
        watchedSessionIDs = sessionIDs
        _ = try await reconcile()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        childParentIDs.removeAll()
    }

    @discardableResult
    public func reconcile() async throws -> OpenCodeReconciliation {
        let sessions = try await fetchSessions()
        let allStatuses = try await fetchStatuses()
        let selectedSessions = sessions.filter {
            $0.parentID == nil && (watchedSessionIDs.isEmpty || watchedSessionIDs.contains($0.id))
        }
        let selectedIDs = Set(selectedSessions.map(\.id))
        var roots = Dictionary(uniqueKeysWithValues: selectedIDs.map { ($0, $0) })
        var selectedSubagents: [OpenCodeSession] = []
        var remaining = sessions.filter { $0.parentID != nil }
        while !remaining.isEmpty {
            var unresolved: [OpenCodeSession] = []
            var foundChild = false
            for child in remaining {
                guard let parentID = child.parentID, let rootID = roots[parentID] else {
                    unresolved.append(child)
                    continue
                }
                roots[child.id] = rootID
                selectedSubagents.append(child)
                foundChild = true
            }
            guard foundChild else { break }
            remaining = unresolved
        }
        childParentIDs = Dictionary(uniqueKeysWithValues: selectedSubagents.compactMap { child in
            roots[child.id].map { (child.id, $0) }
        })
        let trackedIDs = selectedIDs.union(selectedSubagents.map(\.id))
        let statuses = allStatuses.filter { trackedIDs.contains($0.key) }

        var messages: [String: [ChatTranscriptEntry]] = [:]
        for session in selectedSessions {
            messages[session.id] = try await fetchMessages(sessionID: session.id)
        }

        let permissions = try await fetchPermissions().filter {
            selectedIDs.contains($0.sessionID)
        }
        let snapshot = OpenCodeReconciliation(
            sessions: selectedSessions,
            subagents: selectedSubagents,
            statuses: statuses,
            messages: messages,
            permissions: permissions
        )
        await deliver(snapshot: snapshot)
        return snapshot
    }

    /// Sends text through OpenCode's async prompt endpoint. It never creates a
    /// session, runs a local command, or accepts an arbitrary URL.
    public func sendPrompt(sessionID: String, text: String) async throws {
        guard !sessionID.isEmpty else { throw OpenCodeNativeClientError.invalidSessionID }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenCodeNativeClientError.emptyPrompt
        }
        let body: [String: Any] = [
            "parts": [["type": "text", "text": text]]
        ]
        _ = try await request(
            method: "POST",
            path: ["session", sessionID, "prompt_async"],
            body: body,
            acceptedStatuses: [200, 202, 204]
        )
        await eventHandler(BridgeEvent(
            kind: .promptSubmitted,
            source: .opencode,
            sessionID: sessionID,
            timestamp: Date(),
            nativeSession: NativeSessionConnection(
                transport: .openCodeServer,
                conversationID: sessionID,
                endpoint: configuration.baseURL.absoluteString
            ),
            prompt: text
        ))
    }

    /// Replies only with the three OpenCode permission choices. The caller must
    /// select the reply; the client never auto-approves a permission request.
    public func respondToPermission(
        sessionID: String,
        permissionID: String,
        reply: OpenCodePermissionReply
    ) async throws {
        guard !sessionID.isEmpty else { throw OpenCodeNativeClientError.invalidSessionID }
        guard !permissionID.isEmpty else { throw OpenCodeNativeClientError.invalidPermissionID }
        _ = try await request(
            method: "POST",
            path: ["session", sessionID, "permissions", permissionID],
            body: ["response": reply.rawValue],
            acceptedStatuses: [200, 204]
        )
    }

    public func listPermissions() async throws -> [OpenCodePermissionRequest] {
        try await fetchPermissions()
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await consumeStream()
                attempt = 0
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                let delay = reconnectPolicy.delayNanoseconds(forAttempt: attempt)
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
        }
    }

    private func consumeStream() async throws {
        var request = try makeRequest(
            method: "GET",
            path: ["event"],
            query: directoryQuery,
            body: nil
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID, !lastEventID.isEmpty {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenCodeNativeClientError.httpStatus(status)
        }

        // Reconcile only after the new stream connection is accepted. This
        // closes the gap between the old stream and the reconnect.
        _ = try await reconcile()

        var parser = OpenCodeSSEParser()
        for try await line in bytes.lines {
            let events = parser.appendLine(line)
            for event in events {
                await handle(event: event)
            }
        }
        for event in parser.finish() {
            await handle(event: event)
        }
        throw OpenCodeNativeClientError.streamEnded
    }

    private func handle(event: OpenCodeSSEEvent) async {
        if let id = event.id, !id.isEmpty {
            lastEventID = id
        }

        let context = OpenCodeNativeEventMapper.sessionContext(from: event)
        if let childID = context?.sessionID, let parentID = context?.parentID {
            childParentIDs[childID] = childParentIDs[parentID] ?? parentID
        }
        let knownParentID = context.flatMap { childParentIDs[$0.sessionID] ?? $0.parentID }
        for bridgeEvent in OpenCodeNativeEventMapper.bridgeEvents(
            for: event,
            sessionScope: watchedSessionIDs,
            nativeEndpoint: configuration.baseURL.absoluteString,
            knownParentID: knownParentID
        ) {
            await eventHandler(bridgeEvent)
        }

        if knownParentID == nil,
           let chat = OpenCodeNativeEventMapper.chatEntry(from: event),
           watchedSessionIDs.isEmpty || watchedSessionIDs.contains(chat.sessionID) {
            await chatHandler(chat.sessionID, [chat.entry])
        }

        if knownParentID == nil,
           let permission = OpenCodeNativeEventMapper.permissionRequest(from: event),
           watchedSessionIDs.isEmpty || watchedSessionIDs.contains(permission.sessionID) {
            await permissionHandler(permission)
        }
        if context?.type == "session.deleted", let sessionID = context?.sessionID {
            childParentIDs[sessionID] = nil
        }
    }

    private func deliver(snapshot: OpenCodeReconciliation) async {
        for session in snapshot.sessions {
            let sessionName = session.title?
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
                ?? "OpenCode session \(session.id)"
            await eventHandler(BridgeEvent(
                kind: .connect,
                source: .opencode,
                sessionID: session.id,
                timestamp: Date(),
                name: sessionName,
                nativeSession: NativeSessionConnection(
                    transport: .openCodeServer,
                    conversationID: session.id,
                    endpoint: configuration.baseURL.absoluteString
                ),
                cwd: session.directory
            ))
            if let status = snapshot.statuses[session.id] {
                let kind: BridgeEventKind
                let activity: String?
                let message: String?
                switch status.state {
                case .busy:
                    kind = .activityStarted
                    activity = "working"
                    message = nil
                case .retry:
                    kind = .activityStarted
                    activity = status.message ?? "retrying"
                    message = nil
                case .idle:
                    kind = .turnInterrupted
                    activity = nil
                    message = OpenCodeNativeEventMapper.latestAssistantMessage(
                        in: snapshot.messages[session.id] ?? []
                    )
                case .unknown:
                    continue
                }
                await eventHandler(BridgeEvent(
                    kind: kind,
                    source: .opencode,
                    sessionID: session.id,
                    timestamp: Date(),
                    name: sessionName,
                    cwd: session.directory,
                    message: message,
                    activity: activity
                ))
            }
            await chatHandler(session.id, snapshot.messages[session.id] ?? [])
        }
        for child in snapshot.subagents {
            guard let parentID = childParentIDs[child.id] ?? child.parentID else { continue }
            let status = snapshot.statuses[child.id]
            let kind: BridgeEventKind
            let activity: String?
            switch status?.state {
            case .idle:
                kind = .subagentCompleted
                activity = nil
            case .retry:
                kind = .subagentActivity
                activity = status?.message ?? "retrying"
            case .busy, .unknown, nil:
                kind = .subagentStarted
                activity = "working"
            }
            await eventHandler(BridgeEvent(
                kind: kind,
                source: .opencode,
                sessionID: parentID,
                timestamp: Date(),
                activity: activity,
                subagentID: child.id,
                subagentType: child.title ?? "OpenCode agent"
            ))
        }
        for permission in snapshot.permissions {
            await permissionHandler(permission)
        }
    }

    private var directoryQuery: [URLQueryItem] {
        guard let directory = configuration.directory, !directory.isEmpty else { return [] }
        return [URLQueryItem(name: "directory", value: directory)]
    }

    private func fetchSessions() async throws -> [OpenCodeSession] {
        let data = try await request(
            method: "GET",
            path: ["session"],
            query: directoryQuery,
            body: nil,
            acceptedStatuses: [200]
        ).data
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeNativeClientError.invalidResponse("OpenCode session response is not an array")
        }
        return values.compactMap { object in
            guard let id = OpenCodeNativeEventMapper.string(object["id"]) else { return nil }
            return OpenCodeSession(
                id: id,
                title: OpenCodeNativeEventMapper.string(object["title"]),
                directory: OpenCodeNativeEventMapper.string(object["directory"]),
                parentID: OpenCodeNativeEventMapper.string(object["parentID"])
                    ?? OpenCodeNativeEventMapper.string(object["parentId"])
                    ?? OpenCodeNativeEventMapper.string(object["parent_id"]),
                createdAt: OpenCodeNativeEventMapper.date(from: (object["time"] as? [String: Any])?["created"]),
                updatedAt: OpenCodeNativeEventMapper.date(from: (object["time"] as? [String: Any])?["updated"])
            )
        }
    }

    private func fetchStatuses() async throws -> [String: OpenCodeSessionStatus] {
        let data = try await request(
            method: "GET",
            path: ["session", "status"],
            query: directoryQuery,
            body: nil,
            acceptedStatuses: [200]
        ).data
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeNativeClientError.invalidResponse("OpenCode status response is not an object")
        }
        var result: [String: OpenCodeSessionStatus] = [:]
        for (sessionID, value) in values {
            guard let status = value as? [String: Any],
                  let rawState = OpenCodeNativeEventMapper.string(status["type"])
            else { continue }
            let state = OpenCodeSessionStatus.State(rawValue: rawState) ?? .unknown
            result[sessionID] = OpenCodeSessionStatus(
                state: state,
                message: OpenCodeNativeEventMapper.string(status["message"]),
                attempt: (status["attempt"] as? NSNumber)?.intValue
            )
        }
        return result
    }

    private func fetchMessages(sessionID: String) async throws -> [ChatTranscriptEntry] {
        let data = try await request(
            method: "GET",
            path: ["session", sessionID, "message"],
            query: directoryQuery + [URLQueryItem(name: "limit", value: "160")],
            body: nil,
            acceptedStatuses: [200]
        ).data
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeNativeClientError.invalidResponse("OpenCode message response is not an array")
        }
        return decodeMessages(values)
    }

    private func fetchPermissions() async throws -> [OpenCodePermissionRequest] {
        let data = try await request(
            method: "GET",
            path: ["permission"],
            query: directoryQuery,
            body: nil,
            acceptedStatuses: [200]
        ).data
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeNativeClientError.invalidResponse("OpenCode permission response is not an array")
        }
        return values.compactMap { object in
            guard let id = OpenCodeNativeEventMapper.string(object["id"]),
                  let sessionID = OpenCodeNativeEventMapper.string(object["sessionID"]) else {
                return nil
            }
            return OpenCodePermissionRequest(
                id: id,
                sessionID: sessionID,
                type: OpenCodeNativeEventMapper.string(object["type"]),
                pattern: (object["pattern"] as? [String]) ?? [],
                title: OpenCodeNativeEventMapper.string(object["title"]),
                messageID: OpenCodeNativeEventMapper.string(object["messageID"])
            )
        }
    }

    private func decodeMessages(_ values: [[String: Any]]) -> [ChatTranscriptEntry] {
        var entries: [ChatTranscriptEntry] = []
        for value in values {
            let info = value["info"] as? [String: Any] ?? value
            let role = OpenCodeNativeEventMapper.string(info["role"]) ?? "assistant"
            let kind: ChatTranscriptKind = role == "user" ? .user : .assistant
            let messageID = OpenCodeNativeEventMapper.string(info["id"]) ?? UUID().uuidString
            let timestamp = OpenCodeNativeEventMapper.date(from: (info["time"] as? [String: Any])?["created"])
            let modelID = OpenCodeNativeEventMapper.string(info["modelID"])
            let providerID = OpenCodeNativeEventMapper.string(info["providerID"])
            let model = OpenCodeNativeEventMapper.qualifiedModel(provider: providerID, model: modelID)
            let parts = value["parts"] as? [[String: Any]] ?? []

            var textParts: [String] = []
            for part in parts {
                switch OpenCodeNativeEventMapper.string(part["type"]) {
                case "text", "reasoning":
                    if let text = OpenCodeNativeEventMapper.string(part["text"]), !text.isEmpty {
                        textParts.append(text)
                    }
                case "tool":
                    entries.append(decodeToolPart(part, messageID: messageID, timestamp: timestamp))
                default:
                    break
                }
            }
            if !textParts.isEmpty {
                entries.append(ChatTranscriptEntry(
                    id: messageID,
                    kind: kind,
                    title: nil,
                    text: textParts.joined(separator: "\n"),
                    detail: nil,
                    timestamp: timestamp,
                    imagePaths: [],
                    model: model
                ))
            }
        }
        return entries
    }

    private func decodeToolPart(
        _ part: [String: Any],
        messageID: String,
        timestamp: Date?
    ) -> ChatTranscriptEntry {
        let partID = OpenCodeNativeEventMapper.string(part["id"]) ?? UUID().uuidString
        let tool = OpenCodeNativeEventMapper.string(part["tool"]) ?? "tool"
        let state = part["state"] as? [String: Any]
        let detail = OpenCodeNativeEventMapper.string(state?["output"])
            ?? OpenCodeNativeEventMapper.string(state?["error"])
        let text = OpenCodeNativeEventMapper.prettyJSON(state?["input"])
            ?? detail
            ?? OpenCodeNativeEventMapper.string(state?["status"])
            ?? ""
        return ChatTranscriptEntry(
            id: "\(messageID):\(partID)",
            kind: .tool,
            title: tool,
            text: text,
            detail: detail,
            timestamp: timestamp,
            imagePaths: [],
            model: nil
        )
    }

    private struct HTTPResult: Sendable {
        let statusCode: Int
        let data: Data
    }

    private func request(
        method: String,
        path: [String],
        query: [URLQueryItem] = [],
        body: [String: Any]?,
        acceptedStatuses: Set<Int>
    ) async throws -> HTTPResult {
        var request = try makeRequest(method: method, path: path, query: query, body: body)
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeNativeClientError.invalidResponse("OpenCode response is not HTTP")
        }
        guard acceptedStatuses.contains(httpResponse.statusCode) else {
            throw OpenCodeNativeClientError.httpStatus(httpResponse.statusCode)
        }
        return HTTPResult(statusCode: httpResponse.statusCode, data: data)
    }

    private func makeRequest(
        method: String,
        path: [String],
        query: [URLQueryItem] = [],
        body: [String: Any]?
    ) throws -> URLRequest {
        var url = configuration.baseURL
        for segment in path {
            guard !segment.isEmpty else {
                throw OpenCodeNativeClientError.invalidConfiguration("OpenCode request path is empty")
            }
            url.appendPathComponent(segment, isDirectory: false)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OpenCodeNativeClientError.invalidConfiguration("OpenCode request URL is invalid")
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let finalURL = components.url else {
            throw OpenCodeNativeClientError.invalidConfiguration("OpenCode request URL is invalid")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.httpBody = try body.map {
            guard JSONSerialization.isValidJSONObject($0) else {
                throw OpenCodeNativeClientError.invalidResponse("OpenCode request body is invalid")
            }
            return try JSONSerialization.data(withJSONObject: $0)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let username = configuration.username, let password = configuration.password {
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
