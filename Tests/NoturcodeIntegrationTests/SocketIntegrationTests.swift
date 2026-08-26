import Darwin
import Foundation
import XCTest
@testable import NoturcodeCore

final class SocketIntegrationTests: XCTestCase {
    func testServerSocketIsPrivateToCurrentUser() throws {
        let socketPath = "/tmp/nc-private-\(UUID().uuidString.prefix(8)).sock"
        let server = UnixSocketServer(path: socketPath) { _ in Data() }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(attributes[.ownerAccountID] as? NSNumber, NSNumber(value: getuid()))
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
    }

    func testServerRefusesToReplaceARegularFileAtSocketPath() throws {
        let socketURL = URL(fileURLWithPath: "/tmp/nc-unsafe-\(UUID().uuidString.prefix(8)).sock")
        try Data("keep".utf8).write(to: socketURL)
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let server = UnixSocketServer(path: socketURL.path) { _ in Data() }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOf: socketURL, encoding: .utf8), "keep")
    }

    func testEnvelopeRoundTripsOverUserLocalSocket() throws {
        let socketPath = "/tmp/nc-roundtrip-\(UUID().uuidString.prefix(8)).sock"
        let event = BridgeEvent(
            kind: .connect,
            source: .codex,
            sessionID: "thr_socket",
            name: "socket smoke",
            terminalSessionID: "w0t1:SOCKET"
        )
        let expected = try JSONEncoder().encode(BridgeEnvelope(event: event))
        let received = expectation(description: "server received envelope")
        let server = UnixSocketServer(path: socketPath) { data in
            XCTAssertEqual(data, expected)
            received.fulfill()
            return Data(#"{"ok":true}"#.utf8)
        }
        try server.start()
        defer { server.stop() }

        let response = try UnixSocketClient.send(expected, path: socketPath)
        XCTAssertEqual(String(data: response, encoding: .utf8), #"{"ok":true}"#)
        wait(for: [received], timeout: 1)
    }

    func testServerWaitsForPayloadAfterAcceptingAClient() throws {
        let socketPath = "/tmp/nc-delayed-\(UUID().uuidString.prefix(8)).sock"
        let payload = Data("delayed payload".utf8)
        let received = expectation(description: "server received delayed payload")
        let server = UnixSocketServer(path: socketPath) { data in
            XCTAssertEqual(data, payload)
            received.fulfill()
            return Data("ack".utf8)
        }
        try server.start()
        defer { server.stop() }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)

        Thread.sleep(forTimeInterval: 0.1)
        var wirePayload = payload
        wirePayload.append(0x0A)
        let written = wirePayload.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        XCTAssertEqual(written, wirePayload.count)
        Darwin.shutdown(descriptor, SHUT_WR)
        var response = [UInt8](repeating: 0, count: 16)
        let count = Darwin.read(descriptor, &response, response.count)
        XCTAssertEqual(String(decoding: response.prefix(max(0, count)), as: UTF8.self), "ack")
        wait(for: [received], timeout: 1)
    }

    func testPairedRemoteHookRoundTripsOverForwardableSocket() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-remote-\(UUID().uuidString)", isDirectory: true)
        let socketPath = "/tmp/nc-remote-\(UUID().uuidString.prefix(8)).sock"
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pairingStore = RemotePairingStore(directoryURL: root.appendingPathComponent("pairing"))
        let processor = RemoteBridgeProcessor(pairings: pairingStore)
        let code = try pairingStore.createCode(hostHint: "fixture-vps")
        let pairResponse = processor.pair(RemotePairRequest(code: code.code, deviceID: "device-1", deviceName: "Fixture"))
        let token = try XCTUnwrap(pairResponse.token)
        let received = expectation(description: "normalized remote event")

        let server = UnixSocketServer(path: socketPath) { data in
            guard let request = try? JSONDecoder().decode(RemoteHookRequest.self, from: data) else {
                return Data(#"{"ok":false}"#.utf8)
            }
            let result = processor.process(request)
            XCTAssertEqual(result.events.first?.kind, .connect)
            XCTAssertEqual(result.events.first?.terminalSessionID, "w0t1:REMOTE")
            received.fulfill()
            return try! JSONEncoder().encode(result.response)
        }
        try server.start()
        defer { server.stop() }

        let request = RemoteHookRequest(
            token: token,
            deviceID: "device-1",
            source: .codex,
            payload: .object([
                "hook_event_name": .string("UserPromptSubmit"),
                "session_id": .string("remote-1"),
                "prompt": .string("nc remote")
            ]),
            environment: ["PWD": "/srv/app"],
            terminalSessionID: "w0t1:REMOTE"
        )
        let responseData = try UnixSocketClient.send(try JSONEncoder().encode(request), path: socketPath)
        let response = try JSONDecoder().decode(RemoteHookResponse.self, from: responseData)

        XCTAssertTrue(response.ok)
        wait(for: [received], timeout: 1)
    }

    func testNewlineFramedRequestStripsDelimiter() throws {
        let socketPath = "/tmp/nc-framed-\(UUID().uuidString.prefix(8)).sock"
        let payload = Data(#"{"type":"remotePair"}"#.utf8)
        let server = UnixSocketServer(path: socketPath) { data in
            XCTAssertEqual(data, payload)
            return Data(#"{"ok":true}"#.utf8)
        }
        try server.start()
        defer { server.stop() }

        var request = payload
        request.append(0x0A)
        let response = try UnixSocketClient.send(request, path: socketPath)
        XCTAssertEqual(String(data: response, encoding: .utf8), #"{"ok":true}"#)
    }

    func testProcessInspectionReturnsCurrentExecutable() throws {
        let current = try XCTUnwrap(ProcessAncestry.inspect(pid: Int32(ProcessInfo.processInfo.processIdentifier)))
        XCTAssertEqual(current.pid, Int32(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(current.command.isEmpty)
    }

    func testSecondServerCannotStealLiveSocket() throws {
        let socketPath = "/tmp/nc-owner-\(UUID().uuidString.prefix(8)).sock"
        let first = UnixSocketServer(path: socketPath) { _ in Data("first".utf8) }
        let second = UnixSocketServer(path: socketPath) { _ in Data("second".utf8) }
        try first.start()
        defer {
            second.stop()
            first.stop()
        }

        XCTAssertThrowsError(try second.start())
        let response = try UnixSocketClient.send(Data("probe".utf8), path: socketPath)
        XCTAssertEqual(String(data: response, encoding: .utf8), "first")
    }
}
