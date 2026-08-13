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
