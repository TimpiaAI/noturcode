import Foundation

/// A small ACP v1 client over a child process' JSON-RPC stdio.
///
/// This client deliberately does not answer permission requests. The caller
/// must display the request and call `respondToPermission` with an explicit
/// decision. Stopping the client only sends `cancelled` outcomes.
public actor ACPStdioClient {
    public typealias EventHandler = @Sendable (ACPEvent) async -> Void

    private let provider: ACPProvider
    private let transport: LineJSONRPCProcess
    private let capabilities: ACPClientCapabilities
    private let clientName: String
    private let clientVersion: String
    private let eventHandler: EventHandler
    private var started = false
    private var canLoadSession = false
    private var pendingPermissionIDs: [String: JSONValue] = [:]

    public init(
        provider: ACPProvider,
        executableURL: URL,
        arguments: [String],
        capabilities: ACPClientCapabilities = ACPClientCapabilities(),
        clientName: String = "noturcode",
        clientVersion: String = "0.1.0",
        eventHandler: @escaping EventHandler
    ) {
        self.provider = provider
        self.transport = LineJSONRPCProcess(configuration: .init(
            executableURL: executableURL,
            arguments: arguments
        ))
        self.capabilities = capabilities
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.eventHandler = eventHandler
    }

    public func start() async throws {
        guard !started else { throw ACPClientError.alreadyStarted }
        do {
            try await transport.start { [weak self] event in
                await self?.receive(event)
            }
            let result = try await transport.request(
                method: "initialize",
                params: .object([
                    "protocolVersion": .number(1),
                    "clientCapabilities": capabilities.jsonValue,
                    "clientInfo": .object([
                        "name": .string(clientName),
                        "title": .string("Noturcode"),
                        "version": .string(clientVersion)
                    ])
                ])
            )
            guard let protocolVersion = result.firstString(at: [["protocolVersion"]]).flatMap(Int.init)
                    ?? result["protocolVersion"]?.intValue else {
                throw ACPClientError.invalidInitializeResponse
            }
            guard protocolVersion == 1 else {
                throw ACPClientError.unsupportedProtocolVersion(protocolVersion)
            }
            canLoadSession = result.value(at: ["agentCapabilities", "loadSession"])?.boolValue ?? false
            started = true
            await eventHandler(.initialized(protocolVersion: protocolVersion))
        } catch {
            await transport.stop()
            throw error
        }
    }

    public func newSession(cwd: String, mcpServers: [JSONValue] = []) async throws -> String {
        try requireStarted()
        let result = try await transport.request(
            method: "session/new",
            params: .object([
                "cwd": .string(cwd),
                "mcpServers": .array(mcpServers)
            ])
        )
        guard let sessionID = result.firstString(at: [["sessionId"], ["sessionID"]]), !sessionID.isEmpty else {
            throw ACPClientError.invalidSessionResponse
        }
        return sessionID
    }

    public func loadSession(sessionID: String, cwd: String, mcpServers: [JSONValue] = []) async throws {
        try requireStarted()
        guard canLoadSession else { throw ACPClientError.loadSessionUnsupported }
        _ = try await transport.request(
            method: "session/load",
            params: .object([
                "sessionId": .string(sessionID),
                "cwd": .string(cwd),
                "mcpServers": .array(mcpServers)
            ])
        )
    }

    public func prompt(sessionID: String, text: String) async throws -> ACPPromptResult {
        try requireStarted()
        let result = try await transport.request(
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ])
            ])
        )
        return ACPPromptResult(
            stopReason: result.firstString(at: [["stopReason"], ["stop_reason"]]),
            rawResult: result
        )
    }

    public func cancel(sessionID: String) async throws {
        try requireStarted()
        _ = try await transport.request(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)])
        )
    }

    public func respondToPermission(
        requestID: JSONValue,
        decision: ACPPermissionDecision
    ) async throws {
        try requireStarted()
        try await transport.respond(id: requestID, result: decision.jsonValue)
        pendingPermissionIDs.removeValue(forKey: Self.permissionKey(requestID))
    }

    public func stop() async {
        for requestID in pendingPermissionIDs.values {
            try? await transport.respond(id: requestID, result: ACPPermissionDecision.cancelled.jsonValue)
        }
        pendingPermissionIDs.removeAll()
        await transport.stop()
        started = false
        canLoadSession = false
    }

    public var isRunning: Bool {
        get async { await transport.isRunning }
    }

    public var supportsLoadSession: Bool { canLoadSession }

    public var providerName: ACPProvider { provider }

    private func requireStarted() throws {
        guard started else { throw ACPClientError.notStarted }
    }

    private func receive(_ event: JSONRPCLineEvent) async {
        switch event {
        case let .malformed(line):
            await eventHandler(.malformed(line))
        case let .message(message):
            guard let mapped = ACPMessageMapper.map(message) else { return }
            if case let .permissionRequested(request) = mapped {
                pendingPermissionIDs[Self.permissionKey(request.requestID)] = request.requestID
            }
            await eventHandler(mapped)
        }
    }

    private static func permissionKey(_ id: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(id) else { return String(describing: id) }
        return String(decoding: data, as: UTF8.self)
    }
}
