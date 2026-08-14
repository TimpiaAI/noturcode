import Foundation
import XCTest
@testable import NoturcodeCore

private final class OpenCodeStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [Data?] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requests.append(request)
        Self.requestBodies.append(Self.bodyData(for: request))
        let response = HTTPURLResponse(
            url: url,
            statusCode: request.httpMethod == "GET" ? 200 : 204,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

final class OpenCodeNativeClientTests: XCTestCase {
    func testConfigurationRequiresExplicitLocalPortAndDoesNotScan() throws {
        let local = try OpenCodeServerConfiguration(
            baseURL: URL(string: "http://localhost:4096")!
        )
        XCTAssertEqual(local.baseURL.absoluteString, "http://localhost:4096")

        XCTAssertThrowsError(try OpenCodeServerConfiguration(
            baseURL: URL(string: "http://example.com:4096")!
        ))
        XCTAssertThrowsError(try OpenCodeServerConfiguration(
            baseURL: URL(string: "http://localhost")!
        ))

        let environment = try OpenCodeServerConfiguration.fromEnvironment([
            "OPENCODE_SERVER_PASSWORD": "must-not-be-used-without-a-url"
        ])
        XCTAssertNil(environment)
    }

    func testEnvironmentUsesOnlyConfiguredURLAndKnownServerCredentials() throws {
        let configuration = try XCTUnwrap(
            OpenCodeServerConfiguration.fromEnvironment([
                "NOTURCODE_OPENCODE_URL": "http://127.0.0.1:4096",
                "OPENCODE_SERVER_USERNAME": "opencode",
                "OPENCODE_SERVER_PASSWORD": "secret",
                "NOTURCODE_OPENCODE_DIRECTORY": "/tmp/workspace"
            ])
        )

        XCTAssertEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:4096")
        XCTAssertEqual(configuration.username, "opencode")
        XCTAssertEqual(configuration.password, "secret")
        XCTAssertEqual(configuration.directory, "/tmp/workspace")
    }

    func testSSEParserSupportsIDsMultilineDataAndCRLF() {
        var parser = OpenCodeSSEParser()
        let first = parser.append(Data("id: 17\r\nevent: message\r\ndata: {\"a\":\r\n".utf8))
        XCTAssertTrue(first.isEmpty)

        let events = parser.append(Data("data: 1}\r\n\r\n".utf8))
        XCTAssertEqual(events, [
            OpenCodeSSEEvent(
                id: "17",
                event: "message",
                data: "{\"a\":\n1}"
            )
        ])
        XCTAssertEqual(parser.lastEventID, "17")
    }

    func testSSEParserIgnoresCommentsAndResetsEventIDAfterDispatch() {
        var parser = OpenCodeSSEParser()
        let events = parser.append(Data(": heartbeat\nid: 8\ndata: ok\n\n".utf8))
        XCTAssertEqual(events.first?.id, "8")
        XCTAssertEqual(events.first?.data, "ok")

        let next = parser.append(Data("data: next\n\n".utf8))
        XCTAssertNil(next.first?.id)
        XCTAssertEqual(parser.lastEventID, "8")
    }

    func testReconnectBackoffIsBounded() {
        let policy = OpenCodeReconnectPolicy(delaysNanoseconds: [1, 2, 3])
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 1), 1)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 2), 2)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 20), 3)
    }

    func testMapperReadsOpenCodeEnvelopeFromLocalSSERoute() {
        let event = OpenCodeSSEEvent(
            id: "server-event-1",
            event: "message",
            data: """
            {"id":"payload-id","type":"session.status","properties":{
              "sessionID":"ses_local",
              "status":{"type":"busy"}
            }}
            """
        )

        let mapped = OpenCodeNativeEventMapper.bridgeEvents(
            for: event,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped.first?.kind, .activityStarted)
        XCTAssertEqual(mapped.first?.source, .opencode)
        XCTAssertEqual(mapped.first?.sessionID, "ses_local")
        XCTAssertEqual(mapped.first?.activity, "working")
    }

    func testMapperConnectsNewSessionWithNativeOpenCodeIdentity() {
        let event = OpenCodeSSEEvent(
            event: "message",
            data: """
            {"type":"session.created","properties":{
              "info":{"id":"ses_new","title":"Native task","directory":"/tmp/workspace"}
            }}
            """
        )

        let mapped = OpenCodeNativeEventMapper.bridgeEvents(
            for: event,
            nativeEndpoint: "http://localhost:4096"
        )
        XCTAssertEqual(mapped.first?.kind, .connect)
        XCTAssertEqual(mapped.first?.nativeSession?.transport, .openCodeServer)
        XCTAssertEqual(mapped.first?.nativeSession?.conversationID, "ses_new")
        XCTAssertEqual(mapped.first?.nativeSession?.endpoint, "http://localhost:4096")
        XCTAssertEqual(mapped.first?.name, "Native task")
        XCTAssertEqual(mapped.first?.cwd, "/tmp/workspace")
    }

    func testMapperProducesSafePermissionAndToolChatEvents() throws {
        let permissionEvent = OpenCodeSSEEvent(
            event: "message",
            data: """
            {"type":"permission.updated","properties":{
              "id":"perm-1","sessionID":"ses_local","type":"edit",
              "pattern":["src/**"],"title":"Edit source"
            }}
            """
        )
        let permission = try XCTUnwrap(
            OpenCodeNativeEventMapper.permissionRequest(from: permissionEvent)
        )
        XCTAssertEqual(permission.id, "perm-1")
        XCTAssertEqual(permission.sessionID, "ses_local")
        XCTAssertEqual(permission.pattern, ["src/**"])

        let toolEvent = OpenCodeSSEEvent(
            event: "message",
            data: """
            {"type":"message.part.updated","properties":{
              "part":{"id":"part-1","sessionID":"ses_local",
                "messageID":"msg-1","type":"tool","tool":"bash",
                "state":{"status":"running","input":{"command":"echo safe"}}}
            }}
            """
        )
        let chat = try XCTUnwrap(OpenCodeNativeEventMapper.chatEntry(from: toolEvent))
        XCTAssertEqual(chat.sessionID, "ses_local")
        XCTAssertEqual(chat.entry.kind, .tool)
        XCTAssertEqual(chat.entry.title, "bash")
        XCTAssertTrue(chat.entry.text.contains("\"command\":\"echo safe\""))
    }

    func testPermissionReplyHasOnlyOpenCodeChoices() {
        XCTAssertEqual(
            Set(OpenCodePermissionReply.allCases.map(\.rawValue)),
            ["once", "always", "reject"]
        )
    }

    func testSendAndPermissionUseOnlySafeNativeEndpoints() async throws {
        OpenCodeStubURLProtocol.requests = []
        OpenCodeStubURLProtocol.requestBodies = []
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OpenCodeStubURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        defer { urlSession.invalidateAndCancel() }

        let server = try OpenCodeServerConfiguration(
            baseURL: URL(string: "http://localhost:4096")!
        )
        let client = OpenCodeNativeClient(
            configuration: server,
            urlSession: urlSession
        )

        try await client.sendPrompt(sessionID: "ses_local", text: "hello")
        try await client.respondToPermission(
            sessionID: "ses_local",
            permissionID: "perm-1",
            reply: .reject
        )

        XCTAssertEqual(
            OpenCodeStubURLProtocol.requests.map(\.url?.path),
            ["/session/ses_local/prompt_async", "/session/ses_local/permissions/perm-1"]
        )
        let promptBody = try XCTUnwrap(OpenCodeStubURLProtocol.requestBodies[0])
        let promptObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: promptBody) as? [String: Any]
        )
        let parts = try XCTUnwrap(promptObject["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertEqual(parts.first?["text"] as? String, "hello")

        let permissionBody = try XCTUnwrap(OpenCodeStubURLProtocol.requestBodies[1])
        let permissionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: permissionBody) as? [String: Any]
        )
        XCTAssertEqual(permissionObject["response"] as? String, "reject")
    }
}
