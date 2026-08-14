import Foundation
import XCTest
@testable import NoturcodeCore

final class CodexAppServerClientTests: XCTestCase {
    func testApprovalDecisionIDsPreserveOnlyServerOfferedStringChoices() {
        let params: JSONValue = .object([
            "availableDecisions": .array([
                .string("accept"),
                .object(["acceptWithExecpolicyAmendment": .object([:])]),
                .string("cancel")
            ])
        ])

        XCTAssertEqual(
            CodexAppServerEventMapper.availableDecisionIDs(in: params),
            ["accept", "cancel"]
        )
        XCTAssertNil(CodexAppServerEventMapper.availableDecisionIDs(in: .object([:])))
    }

    func testClientPerformsHandshakeStartsThreadAndStreamsEventsOverStdio() async throws {
        let script = try makeFakeCodexAppServer()
        defer { try? FileManager.default.removeItem(at: script) }

        let threadStarted = expectation(description: "thread started")
        let deltaReceived = expectation(description: "message delta")
        let compacted = expectation(description: "thread compacted")
        let collector = CodexEventCollector()
        let client = CodexAppServerClient(codexURL: script) { event in
            collector.append(event)
            if case .threadStarted = event { threadStarted.fulfill() }
            if case .agentMessageDelta = event { deltaReceived.fulfill() }
            if case .threadCompacted = event { compacted.fulfill() }
        }

        try await client.start()
        let threadID = try await client.startThread(cwd: "/tmp/noturcode-codex")
        try await client.sendPrompt(threadID: threadID, text: "fixture only")
        try await client.compactThread(threadID: threadID)
        await fulfillment(of: [threadStarted, deltaReceived, compacted], timeout: 2)

        XCTAssertEqual(threadID, "thread-fixture-1")
        XCTAssertTrue(collector.events.contains(.threadStarted(
            threadID: "thread-fixture-1",
            cwd: nil,
            model: nil
        )))
        XCTAssertTrue(collector.events.contains(.agentMessageDelta(
            threadID: "thread-fixture-1",
            turnID: "turn-fixture-1",
            itemID: "message-fixture-1",
            delta: "fixture response"
        )))
        XCTAssertTrue(collector.events.contains(.threadCompacted(
            threadID: "thread-fixture-1",
            turnID: "turn-compact-1"
        )))
        await client.stop()
    }

    private func makeFakeCodexAppServer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-codex-server-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        while IFS= read -r line
        do
          if printf '%s' "$line" | /usr/bin/grep -q '"method":"initialize"'; then
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fixture"}}'
          elif printf '%s' "$line" | /usr/bin/grep -q '"method":"thread.*compact.*start"'; then
            printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{}}'
            printf '%s\n' '{"jsonrpc":"2.0","method":"thread/compacted","params":{"threadId":"thread-fixture-1","turnId":"turn-compact-1"}}'
          elif printf '%s' "$line" | /usr/bin/grep -q '"method":"thread.*start"'; then
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread-fixture-1"}}}'
            printf '%s\n' '{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"thread-fixture-1"}}}'
          elif printf '%s' "$line" | /usr/bin/grep -q '"method":"turn.*start"'; then
            printf '%s\n' '{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"thread-fixture-1","turnId":"turn-fixture-1","itemId":"message-fixture-1","delta":"fixture response"}}'
            printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-fixture-1"}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

private final class CodexEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CodexAppServerEvent] = []

    func append(_ event: CodexAppServerEvent) {
        lock.lock()
        values.append(event)
        lock.unlock()
    }

    var events: [CodexAppServerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
