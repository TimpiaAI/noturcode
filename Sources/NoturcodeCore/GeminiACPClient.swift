import Foundation

public actor GeminiACPClient {
    public typealias EventHandler = @Sendable (ACPEvent) async -> Void

    /// `gemini --acp` is the installed CLI's ACP entry point.
    public static let commandArguments = ["--acp"]
    public static let executableCandidates = [
        "/opt/homebrew/bin/gemini",
        "/usr/local/bin/gemini",
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.bun/bin/gemini",
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.npm-global/bin/gemini"
    ].map(URL.init(fileURLWithPath:))

    private let client: ACPStdioClient

    public init(
        executableURL: URL? = nil,
        capabilities: ACPClientCapabilities = ACPClientCapabilities(),
        eventHandler: @escaping EventHandler = { _ in }
    ) {
        client = ACPStdioClient(
            provider: .gemini,
            executableURL: executableURL ?? Self.defaultExecutableURL,
            arguments: Self.commandArguments,
            capabilities: capabilities,
            eventHandler: eventHandler
        )
    }

    public func start() async throws { try await client.start() }

    public func newSession(cwd: String, mcpServers: [JSONValue] = []) async throws -> String {
        try await client.newSession(cwd: cwd, mcpServers: mcpServers)
    }

    public func loadSession(sessionID: String, cwd: String, mcpServers: [JSONValue] = []) async throws {
        try await client.loadSession(sessionID: sessionID, cwd: cwd, mcpServers: mcpServers)
    }

    public func prompt(sessionID: String, text: String) async throws -> ACPPromptResult {
        try await client.prompt(sessionID: sessionID, text: text)
    }

    public func cancel(sessionID: String) async throws { try await client.cancel(sessionID: sessionID) }

    public func respondToPermission(requestID: JSONValue, decision: ACPPermissionDecision) async throws {
        try await client.respondToPermission(requestID: requestID, decision: decision)
    }

    public func stop() async { await client.stop() }

    public var isRunning: Bool { get async { await client.isRunning } }
    public var supportsLoadSession: Bool { get async { await client.supportsLoadSession } }

    private static var defaultExecutableURL: URL {
        executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
            ?? executableCandidates[0]
    }
}
