import Foundation

/// Providers that expose the Agent Client Protocol over local stdio.
public enum ACPProvider: String, Codable, CaseIterable, Sendable {
    case gemini
    case grok
}

public struct ACPClientCapabilities: Codable, Equatable, Sendable {
    public var readTextFile: Bool
    public var writeTextFile: Bool
    public var terminal: Bool

    /// The safe default does not advertise filesystem or terminal proxying.
    /// The client never enables a tool or permission mode implicitly.
    public init(readTextFile: Bool = false, writeTextFile: Bool = false, terminal: Bool = false) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.terminal = terminal
    }

    var jsonValue: JSONValue {
        .object([
            "fs": .object([
                "readTextFile": .bool(readTextFile),
                "writeTextFile": .bool(writeTextFile)
            ]),
            "terminal": .bool(terminal)
        ])
    }
}

public struct ACPPermissionOption: Codable, Equatable, Sendable {
    public let optionID: String
    public let name: String?

    public init(optionID: String, name: String? = nil) {
        self.optionID = optionID
        self.name = name
    }
}

public struct ACPPermissionRequest: Equatable, Sendable {
    public let requestID: JSONValue
    public let sessionID: String
    public let title: String?
    public let description: String?
    public let toolCallID: String?
    public let options: [ACPPermissionOption]
    public let rawParams: JSONValue

    public init(
        requestID: JSONValue,
        sessionID: String,
        title: String? = nil,
        description: String? = nil,
        toolCallID: String? = nil,
        options: [ACPPermissionOption] = [],
        rawParams: JSONValue = .object([:])
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.title = title
        self.description = description
        self.toolCallID = toolCallID
        self.options = options
        self.rawParams = rawParams
    }
}

public enum ACPPermissionDecision: Equatable, Sendable {
    case selected(optionID: String)
    case cancelled

    var jsonValue: JSONValue {
        switch self {
        case let .selected(optionID):
            return .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionID)
                ])
            ])
        case .cancelled:
            return .object([
                "outcome": .object([
                    "outcome": .string("cancelled")
                ])
            ])
        }
    }
}

public enum ACPClientError: Error, Equatable, LocalizedError, Sendable {
    case alreadyStarted
    case notStarted
    case invalidInitializeResponse
    case unsupportedProtocolVersion(Int)
    case invalidSessionResponse
    case invalidPermissionRequest
    case loadSessionUnsupported

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "The ACP client is already started."
        case .notStarted:
            "The ACP client is not started."
        case .invalidInitializeResponse:
            "The ACP initialize response is invalid."
        case let .unsupportedProtocolVersion(version):
            "The ACP protocol version is not supported: \(version)."
        case .invalidSessionResponse:
            "The ACP session response did not contain a session ID."
        case .invalidPermissionRequest:
            "The ACP permission request is missing a request ID or session ID."
        case .loadSessionUnsupported:
            "This ACP agent does not support restoring sessions."
        }
    }
}

public struct ACPPromptResult: Equatable, Sendable {
    public let stopReason: String?
    public let rawResult: JSONValue

    public init(stopReason: String?, rawResult: JSONValue) {
        self.stopReason = stopReason
        self.rawResult = rawResult
    }
}

public enum ACPUpdate: Equatable, Sendable {
    case stateUpdate(sessionID: String, state: String?, stopReason: String?)
    case userMessageChunk(sessionID: String, text: String)
    case agentMessageChunk(sessionID: String, text: String, messageID: String?)
    case agentThoughtChunk(sessionID: String, text: String)
    case toolCall(sessionID: String, callID: String?, title: String?, status: String?, raw: JSONValue)
    case toolCallUpdate(sessionID: String, callID: String?, status: String?, raw: JSONValue)
    case plan(sessionID: String, text: String)
    case unknown(sessionID: String?, type: String, raw: JSONValue)
}

public enum ACPEvent: Equatable, Sendable {
    case initialized(protocolVersion: Int)
    case sessionUpdate(ACPUpdate)
    case permissionRequested(ACPPermissionRequest)
    case serverRequest(id: JSONValue, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case malformed(String)
}

public enum ACPMessageMapper {
    public static func map(_ message: LineJSONRPCMessage) -> ACPEvent? {
        guard let method = message.method else { return nil }
        let params = message.params ?? .object([:])

        if method == "session/update" {
            return .sessionUpdate(mapUpdate(params))
        }

        if method == "session/request_permission" {
            guard let requestID = message.id,
                  let request = mapPermissionRequest(id: requestID, params: params) else {
                if let id = message.id {
                    return .serverRequest(id: id, method: method, params: params)
                }
                return .notification(method: method, params: params)
            }
            return .permissionRequested(request)
        }

        if let id = message.id {
            return .serverRequest(id: id, method: method, params: params)
        }
        return .notification(method: method, params: params)
    }

    private static func mapPermissionRequest(id: JSONValue, params: JSONValue) -> ACPPermissionRequest? {
        guard let sessionID = firstString(params, paths: [["sessionId"], ["sessionID"]]),
              !sessionID.isEmpty else { return nil }

        let options: [ACPPermissionOption]
        if case let .array(values) = params["options"] {
            options = values.compactMap { value in
                guard let optionID = firstString(value, paths: [["optionId"], ["optionID"], ["id"]]),
                      !optionID.isEmpty else { return nil }
                return ACPPermissionOption(
                    optionID: optionID,
                    name: firstString(value, paths: [["name"], ["title"], ["label"]])
                )
            }
        } else {
            options = []
        }

        return ACPPermissionRequest(
            requestID: id,
            sessionID: sessionID,
            title: firstString(params, paths: [["title"], ["name"]]),
            description: firstString(params, paths: [["description"], ["message"]]),
            toolCallID: firstString(params, paths: [["toolCallId"], ["toolCallID"], ["toolCall", "id"]]),
            options: options,
            rawParams: params
        )
    }

    private static func mapUpdate(_ params: JSONValue) -> ACPUpdate {
        let update = params["update"] ?? params
        let sessionID = firstString(update, paths: [["sessionId"], ["sessionID"]])
            ?? firstString(params, paths: [["sessionId"], ["sessionID"]])
            ?? ""
        let type = firstString(update, paths: [["sessionUpdate"], ["type"]]) ?? "unknown"

        switch type {
        case "state_update", "stateUpdate":
            return .stateUpdate(
                sessionID: sessionID,
                state: firstString(update, paths: [["state"], ["status"]]),
                stopReason: firstString(update, paths: [["stopReason"], ["stop_reason"]])
            )
        case "user_message_chunk", "userMessageChunk":
            return .userMessageChunk(sessionID: sessionID, text: textValue(update) ?? "")
        case "agent_message_chunk", "agentMessageChunk":
            return .agentMessageChunk(
                sessionID: sessionID,
                text: textValue(update) ?? "",
                messageID: firstString(update, paths: [["messageId"], ["messageID"], ["id"]])
            )
        case "agent_thought_chunk", "agentThoughtChunk":
            return .agentThoughtChunk(sessionID: sessionID, text: textValue(update) ?? "")
        case "tool_call", "toolCall":
            return .toolCall(
                sessionID: sessionID,
                callID: firstString(update, paths: [["toolCallId"], ["toolCallID"], ["callId"], ["id"]]),
                title: firstString(update, paths: [["title"], ["name"], ["toolName"]]),
                status: firstString(update, paths: [["status"], ["state"]]),
                raw: update
            )
        case "tool_call_update", "toolCallUpdate":
            return .toolCallUpdate(
                sessionID: sessionID,
                callID: firstString(update, paths: [["toolCallId"], ["toolCallID"], ["callId"], ["id"]]),
                status: firstString(update, paths: [["status"], ["state"]]),
                raw: update
            )
        case "plan":
            return .plan(sessionID: sessionID, text: textValue(update) ?? "")
        default:
            return .unknown(sessionID: sessionID.isEmpty ? nil : sessionID, type: type, raw: update)
        }
    }

    private static func firstString(_ value: JSONValue, paths: [[String]]) -> String? {
        value.firstString(at: paths)?.nilIfEmpty
    }

    private static func textValue(_ value: JSONValue) -> String? {
        switch value {
        case let .string(text):
            return text
        case let .array(values):
            let text = values.compactMap(textValue).filter { !$0.isEmpty }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        case let .object(object):
            for key in ["text", "content", "data", "message", "output", "result", "entries", "plan"] {
                if let text = object[key].flatMap(textValue), !text.isEmpty { return text }
            }
            return nil
        case .number, .bool, .null:
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
