import Foundation
import XCTest
@testable import NoturcodeCore

final class RemoteImageUploadPlanTests: XCTestCase {
    private struct ShellResult {
        let exitCode: Int32
        let output: String
        let error: String
    }

    func testAcceptsCommonSSHHostForms() {
        let validHosts = [
            "gprc",
            "148.251.90.179",
            "vps.example.com",
            "root@gprc",
            "root@2001:db8::1",
            "root@[2001:db8::1]",
            "root@fe80::1%en0"
        ]

        for host in validHosts {
            XCTAssertTrue(RemoteImageUploadPlan.isValidHost(host), host)
        }
    }

    func testRejectsUnsafeOrIncompleteSSHHosts() {
        let invalidHosts = [
            "",
            "-oProxyCommand=bad",
            "root@",
            "@gprc",
            "root@@gprc",
            "host name",
            "host;touch",
            "host\nbad",
            "host/path",
            String(repeating: "a", count: 256)
        ]

        for host in invalidHosts {
            XCTAssertFalse(RemoteImageUploadPlan.isValidHost(host), host)
        }
    }

    func testBuildsOneNonInteractiveSSHCommand() throws {
        let fileName = "image-00000000-0000-0000-0000-000000000000.png"
        let arguments = try XCTUnwrap(RemoteImageUploadPlan.sshArguments(host: "root@gprc", fileName: fileName))

        XCTAssertEqual(arguments.filter { $0 == "root@gprc" }.count, 1)
        XCTAssertEqual(arguments.prefix(6), ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--"])
        XCTAssertTrue(arguments.last?.contains("cat >") == true)
        XCTAssertTrue(arguments.last?.contains("chmod 600") == true)
        XCTAssertTrue(arguments.last?.contains("trap 'rm -f") == true)
        XCTAssertTrue(arguments.last?.contains(fileName) == true)
    }

    func testReusesThePairedWorkspaceControlSocket() throws {
        let arguments = try XCTUnwrap(RemoteImageUploadPlan.sshArguments(
            host: "root@gprc",
            fileName: "image-00000000-0000-0000-0000-000000000000.png",
            controlPath: "/tmp/noturcode-ssh.ABC123/control"
        ))

        XCTAssertEqual(arguments.prefix(2), ["-S", "/tmp/noturcode-ssh.ABC123/control"])
        XCTAssertTrue(arguments.contains("ProxyCommand=/usr/bin/false"))
        XCTAssertEqual(arguments.filter { $0 == "root@gprc" }.count, 1)
    }

    func testRejectsUnsafeControlSocketPaths() {
        let unsafePaths = [
            "relative.sock",
            "/tmp/socket name",
            "/tmp/a;bad",
            "/tmp/noturcode-ssh.ABC12/control",
            "/tmp/noturcode-ssh.ABC123/other",
            "/tmp/noturcode-ssh-other.ABC123/control",
            "/" + String(repeating: "a", count: 104)
        ]

        for path in unsafePaths {
            XCTAssertNil(RemoteImageUploadPlan.sshArguments(
                host: "gprc",
                fileName: "image-00000000-0000-0000-0000-000000000000.png",
                controlPath: path
            ), path)
        }
    }

    func testRejectsInjectedRemoteFileNames() {
        let invalidNames = [
            "image.png; touch bad",
            "../image.png",
            "image name.png",
            "image.png\nwhoami",
            "-image.png"
        ]

        for fileName in invalidNames {
            XCTAssertNil(RemoteImageUploadPlan.sshArguments(host: "gprc", fileName: fileName), fileName)
        }
    }

    func testValidatesOnlyAbsoluteSafeRemotePaths() {
        XCTAssertEqual(
            RemoteImageUploadPlan.validatedRemotePath("/root/.cache/noturcode/attachments/image-A.png\n"),
            "/root/.cache/noturcode/attachments/image-A.png"
        )
        XCTAssertNil(RemoteImageUploadPlan.validatedRemotePath("relative/image.png"))
        XCTAssertNil(RemoteImageUploadPlan.validatedRemotePath("/root/image name.png"))
        XCTAssertNil(RemoteImageUploadPlan.validatedRemotePath("/root/image.png\n/root/other.png"))
        XCTAssertNil(RemoteImageUploadPlan.validatedRemotePath("/root/image.png;whoami"))
    }

    func testImageLimitIsExactlyTwentyMiB() {
        XCTAssertEqual(RemoteImageUploadPlan.maximumImageBytes, 20 * 1_024 * 1_024)
    }

    func testGeneratedFileNamesAreUniqueAndSafe() {
        let first = RemoteImageUploadPlan.fileName(uuid: UUID())
        let second = RemoteImageUploadPlan.fileName(uuid: UUID())

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("image-"))
        XCTAssertTrue(first.hasSuffix(".png"))
        XCTAssertNotNil(RemoteImageUploadPlan.sshArguments(host: "gprc", fileName: first))
    }

    func testRemoteCommandStreamsBinaryBytesWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-upload-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x10, 0x0A])
        try bytes.write(to: input)

        let arguments = try XCTUnwrap(RemoteImageUploadPlan.sshArguments(
            host: "gprc",
            fileName: "image-00000000-0000-0000-0000-000000000000.png"
        ))
        let command = try XCTUnwrap(arguments.last)
        let result = try runShell(command, input: input, home: root)

        XCTAssertEqual(result.exitCode, 0, result.error)
        let remotePath = try XCTUnwrap(RemoteImageUploadPlan.validatedRemotePath(result.output))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remotePath)), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: remotePath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = URL(fileURLWithPath: remotePath).deletingLastPathComponent().path
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRemoteCommandStopsWhenDirectorySetupFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-upload-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.png")
        try Data([0x01]).write(to: input)
        let cachePath = root.appendingPathComponent(".cache")
        try Data([0x02]).write(to: cachePath)

        let arguments = try XCTUnwrap(RemoteImageUploadPlan.sshArguments(
            host: "gprc",
            fileName: "image-00000000-0000-0000-0000-000000000000.png"
        ))
        let result = try runShell(try XCTUnwrap(arguments.last), input: input, home: root)

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".cache/noturcode/attachments/image-00000000-0000-0000-0000-000000000000.png").path
        ))
    }

    func testRemoteTerminalRegistryKeepsTheRichSSHIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-remote-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = RemoteTerminalRegistry(directoryURL: root)
        let identity = TerminalIdentity(
            application: .iterm,
            nativeSessionID: "w0t0p3:23FB1192-1E94-4C6D-AFD8-958D891E2C3B",
            remoteHost: "gprc",
            sshControlPath: "/tmp/noturcode-ssh.ABC123/control"
        )

        try registry.register(terminalSessionID: identity.sessionID)
        let target = try XCTUnwrap(registry.targets().first)

        XCTAssertEqual(target.uniqueID, "23FB1192-1E94-4C6D-AFD8-958D891E2C3B")
        XCTAssertEqual(target.identity?.remoteHost, "gprc")
        XCTAssertEqual(target.identity?.sshControlPath, "/tmp/noturcode-ssh.ABC123/control")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("23FB1192-1E94-4C6D-AFD8-958D891E2C3B.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRemoteTerminalRegistryKeepsLatestSessionSnapshotUntilWorkspaceCloses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-remote-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = RemoteTerminalRegistry(directoryURL: root)
        let identity = TerminalIdentity(
            application: .iterm,
            nativeSessionID: "w0t0p3:23FB1192-1E94-4C6D-AFD8-958D891E2C3B",
            remoteHost: "gprc"
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let session = TrackedSession(
            key: SessionKey(source: .codex, sessionID: "remote-chat"),
            name: "gprc 2",
            terminal: TerminalTarget(sessionID: identity.sessionID),
            sourceProcessID: 42,
            cwd: "/root/project",
            state: .working,
            connectedAt: now,
            lastPromptAt: now,
            stateChangedAt: now
        )

        try registry.register(terminalSessionID: identity.sessionID)
        try registry.remember(session)

        let restored = try XCTUnwrap(registry.sessions().first)
        XCTAssertEqual(restored.key, session.key)
        XCTAssertEqual(restored.name, "gprc 2")
        XCTAssertEqual(restored.terminal?.identity?.remoteHost, "gprc")

        try registry.forgetSession(session.key)
        XCTAssertTrue(registry.sessions().isEmpty)
        XCTAssertEqual(registry.targets().count, 1)
    }

    func testRemoteTerminalRegistryRejectsLocalOrMalformedTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-remote-registry-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = RemoteTerminalRegistry(directoryURL: root)

        XCTAssertThrowsError(try registry.register(terminalSessionID: "w0t0p3:LOCAL"))
        XCTAssertThrowsError(try registry.register(terminalSessionID: "terminal:iterm:session:bad?remoteHost=gprc"))
        XCTAssertTrue(registry.targets().isEmpty)
    }

    func testRemoteTerminalRegistryUnregistersOnlyTheExactSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-remote-registry-remove-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = RemoteTerminalRegistry(directoryURL: root)
        let first = TerminalIdentity(
            application: .iterm,
            nativeSessionID: "w0t0p3:23FB1192-1E94-4C6D-AFD8-958D891E2C3B",
            remoteHost: "gprc"
        )
        let second = TerminalIdentity(
            application: .iterm,
            nativeSessionID: "w0t0p4:4BAC8AC1-C012-4EE4-8999-0B712C3B68D3",
            remoteHost: "other-vps"
        )
        try registry.register(terminalSessionID: first.sessionID)
        try registry.register(terminalSessionID: second.sessionID)

        try registry.unregister(terminalSessionID: first.sessionID)

        XCTAssertEqual(registry.targets().map(\.uniqueID), ["4BAC8AC1-C012-4EE4-8999-0B712C3B68D3"])
    }

    func testControlSocketMustBeOwnedLiveAndInsideAPrivateDirectory() throws {
        let directory = URL(fileURLWithPath: "/tmp/noturcode-ssh.\(String(UUID().uuidString.prefix(6)))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control").path

        XCTAssertFalse(RemoteImageUploadPlan.isUsableControlSocket(path))
        let server = UnixSocketServer(path: path) { _ in Data() }
        try server.start()
        XCTAssertTrue(RemoteImageUploadPlan.isUsableControlSocket(path))
        server.stop()
        XCTAssertFalse(RemoteImageUploadPlan.isUsableControlSocket(path))
    }

    func testBoundedProcessRunnerDrainsLargeOutputWithoutDeadlock() throws {
        let result = try BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero; head -c 200000 /dev/zero >&2"],
            timeout: 3
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 200_000)
        XCTAssertEqual(result.error.count, 200_000)
    }

    func testBoundedProcessRunnerStopsAStalledUpload() {
        let started = Date()

        XCTAssertThrowsError(try BoundedProcessRunner.run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.05
        )) { error in
            XCTAssertEqual(error as? BoundedProcessRunnerError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    private func runShell(_ command: String, input: URL, home: URL) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { _, new in new }
        let inputHandle = try FileHandle(forReadingFrom: input)
        defer { try? inputHandle.close() }
        process.standardInput = inputHandle
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return ShellResult(
            exitCode: process.terminationStatus,
            output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
