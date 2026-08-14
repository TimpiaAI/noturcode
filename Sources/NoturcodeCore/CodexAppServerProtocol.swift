import Foundation

public enum CodexAppServerEvent: Equatable, Sendable {
    case threadStarted(threadID: String, cwd: String?, model: String?)
    case turnStarted(threadID: String, turnID: String)
    case agentMessageDelta(threadID: String, turnID: String, itemID: String, delta: String)
    case activity(
        threadID: String,
        itemID: String,
        title: String,
        detail: String,
        completed: Bool
    )
    case askingYou(threadID: String?, requestID: JSONValue?, method: String, params: JSONValue)
    case turnCompleted(threadID: String, turnID: String, finalMessage: String?)
    case failed(threadID: String?, message: String)
}

public enum CodexAppServerEventMapper {
    public static func map(_ message: LineJSONRPCMessage) -> CodexAppServerEvent? {
        guard let method = message.method else { return nil }
        let params = message.params ?? .object([:])
        let threadID = params.firstString(at: [["threadId"], ["thread", "id"]])
        switch method {
        case "thread/started":
            guard let threadID else { return nil }
            return .threadStarted(
                threadID: threadID,
                cwd: params.firstString(at: [["thread", "cwd"], ["cwd"]]),
                model: params.firstString(at: [["thread", "model"], ["model"]])
            )
        case "turn/started":
            guard let threadID,
                  let turnID = params.firstString(at: [["turn", "id"], ["turnId"]]) else { return nil }
            return .turnStarted(threadID: threadID, turnID: turnID)
        case "item/agentMessage/delta":
            guard let threadID,
                  let turnID = params.firstString(for: ["turnId"]),
                  let itemID = params.firstString(for: ["itemId"]),
                  let delta = params.firstString(for: ["delta"]) else { return nil }
            return .agentMessageDelta(threadID: threadID, turnID: turnID, itemID: itemID, delta: delta)
        case "item/started", "item/completed":
            guard let threadID else { return nil }
            let itemID = params.firstString(at: [["item", "id"], ["itemId"]]) ?? UUID().uuidString
            let itemType = params.firstString(at: [["item", "type"], ["type"]]) ?? "tool"
            let rawTitle = params.firstString(at: [
                ["item", "command"], ["item", "name"], ["item", "server"], ["item", "type"], ["type"]
            ]) ?? "working"
            let title = activityTitle(rawTitle, itemType: itemType)
            let detail = (try? String(decoding: JSONEncoder().encode(params), as: UTF8.self)) ?? ""
            return .activity(
                threadID: threadID,
                itemID: itemID,
                title: title,
                detail: detail,
                completed: method == "item/completed"
            )
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/tool/requestUserInput",
             "item/permissions/requestApproval":
            return .askingYou(threadID: threadID, requestID: message.id, method: method, params: params)
        case "turn/completed":
            guard let threadID,
                  let turnID = params.firstString(at: [["turn", "id"], ["turnId"]]) else { return nil }
            return .turnCompleted(
                threadID: threadID,
                turnID: turnID,
                finalMessage: params.firstString(at: [["turn", "lastAgentMessage"], ["lastAgentMessage"]])
            )
        case "error":
            return .failed(
                threadID: threadID,
                message: params.firstString(for: ["message", "error"]) ?? "Codex app-server error"
            )
        default:
            return nil
        }
    }

    private static func activityTitle(_ raw: String, itemType: String) -> String {
        switch itemType {
        case "commandExecution": "Run command"
        case "fileChange": "Edit files"
        case "mcpToolCall": "Use MCP tool"
        case "webSearch": "Search web"
        case "imageView": "View image"
        case "agentMessage", "userMessage", "reasoning", "plan": itemType
        default: raw
        }
    }
}

public actor CodexAppServerClient {
    public typealias EventHandler = @Sendable (CodexAppServerEvent) async -> Void

    private let transport: LineJSONRPCProcess
    private let eventHandler: EventHandler

    public init(codexURL: URL, eventHandler: @escaping EventHandler) {
        transport = LineJSONRPCProcess(configuration: .init(
            executableURL: codexURL,
            arguments: ["app-server", "--listen", "stdio://"]
        ))
        self.eventHandler = eventHandler
    }

    public func start() async throws {
        try await transport.start { [eventHandler] event in
            guard case let .message(message) = event,
                  let mapped = CodexAppServerEventMapper.map(message) else { return }
            await eventHandler(mapped)
        }
        _ = try await transport.request(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("noturcode"),
                    "title": .string("Noturcode"),
                    "version": .string("0.1.0")
                ]),
                "capabilities": .object([:])
            ])
        )
        try await transport.notify(method: "initialized")
    }

    public func startThread(cwd: String, model: String? = nil) async throws -> String {
        var values: [String: JSONValue] = [
            "cwd": .string(cwd),
            "experimentalRawEvents": .bool(false)
        ]
        if let model { values["model"] = .string(model) }
        let result = try await transport.request(method: "thread/start", params: .object(values))
        guard let threadID = result.firstString(at: [["thread", "id"], ["threadId"]]) else {
            throw LineJSONRPCProcessError.requestFailed("thread/start returned no thread id")
        }
        return threadID
    }

    public func resumeThread(_ threadID: String) async throws {
        _ = try await transport.request(
            method: "thread/resume",
            params: .object(["threadId": .string(threadID)])
        )
    }

    public func sendPrompt(threadID: String, text: String, localImagePaths: [String] = []) async throws {
        var input: [JSONValue] = [
            .object(["type": .string("text"), "text": .string(text)])
        ]
        input.append(contentsOf: localImagePaths.map {
            .object(["type": .string("localImage"), "path": .string($0)])
        })
        _ = try await transport.request(
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "input": .array(input)
            ])
        )
    }

    public func respondToServerRequest(id: JSONValue, result: JSONValue) async throws {
        try await transport.respond(id: id, result: result)
    }

    public func stop() async {
        await transport.stop()
    }
}
