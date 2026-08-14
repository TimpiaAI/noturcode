import Foundation
import XCTest
@testable import NoturcodeCore

final class ACPClientTests: XCTestCase {
    func testProviderCommandsUseACPStdioWithoutAutoApproval() {
        XCTAssertEqual(GeminiACPClient.commandArguments, ["--acp"])
        XCTAssertEqual(GrokACPClient.commandArguments, ["agent", "stdio"])
        XCTAssertFalse(GeminiACPClient.commandArguments.contains { $0.contains("yolo") || $0.contains("approve") })
        XCTAssertFalse(GrokACPClient.commandArguments.contains { $0.contains("yolo") || $0.contains("approve") })
    }

    func testACPMapperMapsUpdateAndPermissionRequestWithoutAnsweringIt() {
        let update = LineJSONRPCMessage(
            method: "session/update",
            params: .object([
                "sessionId": .string("session-1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("hello")
                    ])
                ])
            ])
        )
        XCTAssertEqual(
            ACPMessageMapper.map(update),
            .sessionUpdate(.agentMessageChunk(sessionID: "session-1", text: "hello", messageID: nil))
        )

        let permission = LineJSONRPCMessage(
            id: .number(7),
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("session-1"),
                "title": .string("Run command"),
                "options": .array([
                    .object([
                        "optionId": .string("allow-once"),
                        "name": .string("Allow once")
                    ])
                ])
            ])
        )
        guard case let .permissionRequested(request) = ACPMessageMapper.map(permission) else {
            return XCTFail("Expected a permission request event")
        }
        XCTAssertEqual(request.requestID, .number(7))
        XCTAssertEqual(request.sessionID, "session-1")
        XCTAssertEqual(request.options, [ACPPermissionOption(optionID: "allow-once", name: "Allow once")])
    }

    func testGeminiClientPerformsACPHandshakeSessionAndPromptOverStdio() async throws {
        let script = try makeFakeACPServer()
        defer { try? FileManager.default.removeItem(at: script) }

        let updateReceived = expectation(description: "agent update received")
        let collector = ACPEventCollector()
        let client = GeminiACPClient(executableURL: script) { event in
            collector.append(event)
            if case .sessionUpdate(.agentMessageChunk) = event {
                updateReceived.fulfill()
            }
        }

        try await client.start()
        let sessionID = try await client.newSession(cwd: "/tmp/noturcode-acp")
        let result = try await client.prompt(sessionID: sessionID, text: "hello")
        await fulfillment(of: [updateReceived], timeout: 2)

        XCTAssertEqual(sessionID, "session-1")
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertTrue(collector.events.contains(.initialized(protocolVersion: 1)))
        await client.stop()
    }

    func testGrokClientUsesACPStdioHandshakeWithoutAlwaysApprove() async throws {
        let script = try makeFakeACPServer()
        defer { try? FileManager.default.removeItem(at: script) }

        let initialized = expectation(description: "Grok ACP initialized")
        let client = GrokACPClient(executableURL: script) { event in
            if case .initialized(protocolVersion: 1) = event {
                initialized.fulfill()
            }
        }

        try await client.start()
        await fulfillment(of: [initialized], timeout: 2)
        let running = await client.isRunning
        XCTAssertTrue(running)
        await client.stop()
        let stopped = await client.isRunning
        XCTAssertFalse(stopped)
    }

    func testACPClientLoadsPersistedSessionOnlyWhenAgentAdvertisesCapability() async throws {
        let script = try makeFakeACPServer()
        defer { try? FileManager.default.removeItem(at: script) }
        let client = GeminiACPClient(executableURL: script) { _ in }

        try await client.start()
        let supportsLoadSession = await client.supportsLoadSession
        XCTAssertTrue(supportsLoadSession)
        try await client.loadSession(sessionID: "persisted-7", cwd: "/tmp/noturcode-acp")
        await client.stop()
    }

    private func makeFakeACPServer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-acp-server-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        while IFS= read -r line
        do
          if printf '%s' "$line" | /usr/bin/grep -q 'initialize'; then
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}'
          elif printf '%s' "$line" | /usr/bin/grep -q 'new'; then
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}'
          elif printf '%s' "$line" | /usr/bin/grep -q 'load'; then
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"currentMode":"default"}}'
          elif printf '%s' "$line" | /usr/bin/grep -q 'prompt'; then
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
          elif printf '%s' "$line" | /usr/bin/grep -q 'session/cancel'; then
            printf '%s\\n' '{"jsonrpc":"2.0","id":4,"result":{}}'
          fi
        done
        """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

private final class ACPEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ACPEvent] = []

    func append(_ event: ACPEvent) {
        lock.lock()
        values.append(event)
        lock.unlock()
    }

    var events: [ACPEvent] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
