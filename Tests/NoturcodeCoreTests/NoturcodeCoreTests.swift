import AppKit
import Carbon
import Foundation
import XCTest
@testable import NoturcodeCore

final class NoturcodeCoreTests: XCTestCase {
    func testRemoteTerminalIdentityRoundTripsUploadHost() throws {
        let identity = TerminalIdentity(
            application: .iterm,
            nativeSessionID: "w0t0p3:ABC-123",
            remoteHost: "gprc",
            sshControlPath: "/tmp/noturcode-ssh.ABC123/control"
        )

        let parsed = try XCTUnwrap(TerminalIdentity.parse(sessionID: identity.sessionID))
        XCTAssertEqual(parsed.nativeSessionID, "w0t0p3:ABC-123")
        XCTAssertEqual(parsed.remoteHost, "gprc")
        XCTAssertEqual(parsed.sshControlPath, "/tmp/noturcode-ssh.ABC123/control")
    }

    func testRemoteImagePasteUsesObservedCommandVWithoutBlockingTextPaste() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let provider = try String(contentsOf: repository.appendingPathComponent("Integrations/iterm2-ask-noturcode.py"))
        let cli = try String(contentsOf: repository.appendingPathComponent("Integrations/noturcode-cli.zsh"))
        let bridge = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeBridge/main.swift"))
        let model = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))
        let uploader = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/RemoteImagePasteCoordinator.swift"))
        let uploadPlan = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeCore/RemoteImageUploadPlan.swift"))
        let processRunner = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeCore/BoundedProcessRunner.swift"))
        let installer = try String(contentsOf: repository.appendingPathComponent("scripts/install.sh"))
        let remoteDocs = try String(contentsOf: repository.appendingPathComponent("docs/REMOTE.md"))

        XCTAssertTrue(provider.contains("KeystrokeMonitor"))
        XCTAssertTrue(provider.contains("REMOTE_TERMINALS"))
        XCTAssertTrue(provider.contains("os.listdir(REMOTE_TERMINALS)"))
        XCTAssertTrue(provider.contains("Keycode.ANSI_V"))
        XCTAssertTrue(provider.contains("Modifier.COMMAND"))
        XCTAssertTrue(provider.contains("paste-image"))
        XCTAssertTrue(provider.contains("KeystrokeFilter"))
        XCTAssertTrue(provider.contains("forbidden_modifiers"))
        XCTAssertTrue(provider.contains("KeystrokeMonitor(connection, session_id)"))
        XCTAssertTrue(provider.contains("KeystrokeFilter(connection, patterns, session_id)"))
        XCTAssertTrue(provider.contains("Modifier.CONTROL"))
        XCTAssertFalse(provider.contains("connected-sessions.json"))
        XCTAssertFalse(provider.contains("BRIDGE, \"paste-image-sessions\""))
        XCTAssertTrue(cli.contains("terminal-id --remote-host \"$host\""))
        XCTAssertTrue(cli.contains("--ssh-control-path \"$control_socket\""))
        XCTAssertTrue(cli.contains("-M -S \"$control_socket\""))
        XCTAssertTrue(cli.contains("mktemp -d /tmp/noturcode-ssh.XXXXXX"))
        XCTAssertTrue(cli.contains("chmod 700 \"$control_dir\""))
        XCTAssertTrue(cli.contains("remote-terminal register --terminal-id \"$terminal_id\""))
        XCTAssertTrue(cli.contains("remote-terminal unregister --terminal-id \"$terminal_id\""))
        XCTAssertTrue(cli.contains("trap 'cleanup_workspace; exit 129' HUP"))
        XCTAssertTrue(cli.contains("trap 'cleanup_workspace; exit 143' TERM"))
        XCTAssertTrue(cli.contains("trap cleanup_workspace EXIT"))
        XCTAssertTrue(cli.contains("trap 'cleanup_pair; exit 129' HUP"))
        XCTAssertTrue(bridge.contains("case \"paste-image\""))
        XCTAssertTrue(model.contains("TerminalImagePasteRequest"))
        XCTAssertTrue(model.contains("remoteImagePaste.handle"))
        XCTAssertTrue(uploader.contains("NSPasteboard.general"))
        XCTAssertTrue(uploader.contains("NSPasteboard.general.string(forType: .string)"))
        XCTAssertTrue(uploader.contains("TerminalTarget(sessionID: request.terminalSessionID)"))
        XCTAssertFalse(uploader.contains("/usr/bin/scp"))
        XCTAssertEqual(uploader.components(separatedBy: "executable: \"/usr/bin/ssh\"").count - 1, 1)
        XCTAssertTrue(uploader.contains("BoundedProcessRunner.run"))
        XCTAssertTrue(processRunner.contains("readDataToEndOfFile"))
        XCTAssertTrue(processRunner.contains("case timedOut"))
        XCTAssertTrue(uploadPlan.contains("cat >"))
        XCTAssertTrue(uploader.contains("insertWithoutSubmitting"))
        XCTAssertTrue(uploader.contains("RemoteTerminalRegistry().targets()"))
        XCTAssertTrue(installer.contains("Reload only the small Noturcode provider"))
        XCTAssertFalse(installer.contains("killall iTerm"))
        XCTAssertTrue(remoteDocs.contains("Image upload reuses that authenticated connection"))
        XCTAssertFalse(remoteDocs.contains("must accept a\nnon-interactive key-based SSH connection"))
    }

    func testITermImagePathInsertDoesNotPressEnter() throws {
        let source = ITermPromptScript.source
        let start = try XCTUnwrap(source.range(of: "on insertWithoutSubmitting"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "end insertWithoutSubmitting"))
        let handler = tail[..<end.upperBound]

        XCTAssertTrue(handler.contains("pasteStart & outgoingText & pasteEnd"))
        XCTAssertTrue(handler.contains("write text"))
        XCTAssertFalse(handler.contains("ASCII character 13"))
    }

    func testAutomaticLaunchPausePersistsUntilExplicitResume() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-launch-policy-\(UUID().uuidString)", isDirectory: true)
        let marker = directory.appendingPathComponent("automatic-launch-paused")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(NoturcodeLaunchPolicy.isAutomaticLaunchPaused(at: marker))
        try NoturcodeLaunchPolicy.pauseAutomaticLaunch(at: marker)
        XCTAssertTrue(NoturcodeLaunchPolicy.isAutomaticLaunchPaused(at: marker))
        try NoturcodeLaunchPolicy.resumeAutomaticLaunch(at: marker)
        XCTAssertFalse(NoturcodeLaunchPolicy.isAutomaticLaunchPaused(at: marker))
    }

    func testQuitPausesHookRelaunchUntilDirectAppLaunch() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appEntry = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppEntry.swift"))
        let bridge = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeBridge/main.swift"))

        XCTAssertTrue(appEntry.contains("NoturcodeLaunchPolicy.resumeAutomaticLaunch()"))
        XCTAssertTrue(appEntry.contains("NoturcodeLaunchPolicy.pauseAutomaticLaunch()"))
        XCTAssertTrue(bridge.contains("NoturcodeLaunchPolicy.isAutomaticLaunchPaused()"))
        XCTAssertTrue(bridge.contains("automatic-launch: \\(automaticLaunchStatus)"))
    }

    func testTranscriptRunStateDetectsClaudeEndTurnAfterLatestPrompt() throws {
        let prompt = ISO8601DateFormatter().date(from: "2026-08-14T08:00:00Z")!
        let active = """
        {"type":"user","timestamp":"2026-08-14T08:00:00Z","message":{"content":"fix it"}}
        {"type":"assistant","timestamp":"2026-08-14T08:00:05Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}
        """
        let finished = active + "\n" + """
        {"type":"assistant","timestamp":"2026-08-14T08:00:10Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}
        """

        XCTAssertFalse(TranscriptRunStateDetector.turnCompleted(
            data: Data(active.utf8),
            source: .claude,
            after: prompt
        ))
        XCTAssertTrue(TranscriptRunStateDetector.turnCompleted(
            data: Data(finished.utf8),
            source: .claude,
            after: prompt
        ))
    }

    func testTranscriptRunStateUsesTheLatestRelevantJSONLEvent() throws {
        let prompt = ISO8601DateFormatter().date(from: "2026-08-14T08:00:00Z")!
        let trailingMetadata = (0..<2_000)
            .map { "{\"type\":\"progress\",\"timestamp\":\"2026-08-14T08:00:11Z\",\"index\":\($0)}" }
            .joined(separator: "\n")
        let finished = """
        {"type":"user","timestamp":"2026-08-14T08:00:00Z","message":{"content":"fix it"}}
        {"type":"assistant","timestamp":"2026-08-14T08:00:10Z","message":{"stop_reason":"end_turn"}}
        \(trailingMetadata)
        """
        XCTAssertTrue(TranscriptRunStateDetector.turnCompleted(
            data: Data(finished.utf8),
            source: .claude,
            after: prompt
        ))

        let resumed = finished + "\n" + """
        {"type":"user","timestamp":"2026-08-14T08:00:12Z","message":{"content":"continue"}}
        """
        XCTAssertFalse(TranscriptRunStateDetector.turnCompleted(
            data: Data(resumed.utf8),
            source: .claude,
            after: prompt
        ))
    }

    func testTranscriptRevisionChangesOnlyWhenFileChanges() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-transcript-revision-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("first\n".utf8).write(to: url)
        let first = try XCTUnwrap(TranscriptRunStateDetector.revision(atPath: url.path))
        let unchanged = try XCTUnwrap(TranscriptRunStateDetector.revision(atPath: url.path))
        XCTAssertEqual(first, unchanged)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()

        let changed = try XCTUnwrap(TranscriptRunStateDetector.revision(atPath: url.path))
        XCTAssertNotEqual(first, changed)
        XCTAssertGreaterThan(changed.size, first.size)
    }

    func testAppReconcilesMissedTranscriptCompletionWithoutHover() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))

        XCTAssertTrue(appModel.contains("startTranscriptReconciliation()"))
        XCTAssertTrue(appModel.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(appModel.contains("session.key.source == .claude"))
        XCTAssertTrue(appModel.contains("TranscriptRunStateDetector.revision"))
        XCTAssertTrue(appModel.contains("previousFingerprints[candidate.key] != fingerprint"))
        XCTAssertTrue(appModel.contains("TranscriptRunStateDetector.turnCompleted"))
        XCTAssertTrue(appModel.contains("kind: .responseCompleted"))
    }

    func testSessionPersistenceUsesPrivateDirectoryAndFilePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-security-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("state/connected-sessions.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let persistence = SessionPersistence(fileURL: fileURL)
        try persistence.save([])
        try persistence.save([])

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTokenCheckpointUsesPrivateDirectoryAndFilePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-checkpoint-security-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("state/token-checkpoints.json")
        let transcriptURL = root.appendingPathComponent("transcript.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("entry".utf8).write(to: transcriptURL)

        TokenUsageCheckpointStore(fileURL: fileURL).mark(
            SessionKey(source: .codex, sessionID: "private"),
            transcriptPath: transcriptURL.path,
            total: 5
        )

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDiagnosticAppendUsesPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-log-security-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("support/spotlight.log")
        defer { try? FileManager.default.removeItem(at: root) }

        try SecureLocalStorage.appendPrivate(Data("first\n".utf8), to: fileURL)
        try SecureLocalStorage.appendPrivate(Data("second\n".utf8), to: fileURL)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "first\nsecond\n")
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPrivateStorageRefusesSymlinkDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-symlink-security-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target.json")
        let link = root.appendingPathComponent("connected-sessions.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SecureLocalStorage.writePrivate(Data("replace".utf8), to: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testCompletionSummaryVisibilityFollowsCurrentSessionState() {
        XCTAssertFalse(SessionState.idle.showsCompletionSummary)
        XCTAssertFalse(SessionState.working.showsCompletionSummary)
        XCTAssertTrue(SessionState.askingYou.showsCompletionSummary)
        XCTAssertTrue(SessionState.done.showsCompletionSummary)
        XCTAssertFalse(SessionState.failed.showsCompletionSummary)
    }

    func testSelectionContextRequestRoundTripsWithoutBecomingAChatEvent() throws {
        let request = SelectionContextRequest(selection: "let answer = 42", terminalSessionID: "w0t1:ABC")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SelectionContextRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.type, "selectionContext")
        XCTAssertThrowsError(try JSONDecoder().decode(BridgeEnvelope.self, from: data))
    }

    func testRemotePairingCodeIsSingleUseAndStoresOnlyATokenHash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-pairing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = RemotePairingStore(directoryURL: root, now: { now })

        let pairing = try store.createCode(hostHint: "demo-vps")
        XCTAssertEqual(pairing.code.count, 6)
        let token = try store.pair(code: pairing.code, deviceID: "device-1", deviceName: "Demo VPS")

        XCTAssertTrue(store.validates(token: token, deviceID: "device-1"))
        XCTAssertFalse(store.validates(token: token + "wrong", deviceID: "device-1"))
        XCTAssertThrowsError(try store.pair(code: pairing.code, deviceID: "device-2", deviceName: "Other"))
        let stored = try String(contentsOf: root.appendingPathComponent("devices/device-1.json"), encoding: .utf8)
        XCTAssertFalse(stored.contains(token))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("devices/device-1.json").path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testRemotePairingRejectsAnExpiredCode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-pairing-expiry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        final class Clock: @unchecked Sendable {
            var value = Date(timeIntervalSince1970: 1_800_000_000)
        }
        let clock = Clock()
        let store = RemotePairingStore(directoryURL: root, now: { clock.value })
        let pairing = try store.createCode(hostHint: "demo-vps", lifetime: 10)
        clock.value = clock.value.addingTimeInterval(11)

        XCTAssertThrowsError(try store.pair(code: pairing.code, deviceID: "device-1", deviceName: "Demo")) { error in
            XCTAssertEqual(error.localizedDescription, "The pairing code expired. Run nc and create a new code.")
        }
    }

    func testRemoteHookRequestRoundTripsWithTerminalIdentity() throws {
        let request = RemoteHookRequest(
            token: "private-test-token",
            deviceID: "vps-1",
            source: .claude,
            payload: .object(["hook_event_name": .string("Stop"), "session_id": .string("remote-1")]),
            environment: ["SSH_CONNECTION": "127.0.0.1 50000 127.0.0.1 22"],
            sourceProcessID: 42,
            terminalSessionID: "w0t1:REMOTE"
        )
        let decoded = try JSONDecoder().decode(RemoteHookRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.type, "remoteHook")
    }

    func testRemoteBridgeRejectsUnknownDeviceThenNormalizesPairedHook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-remote-processor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pairings = RemotePairingStore(directoryURL: root, now: { now })
        let processor = RemoteBridgeProcessor(pairings: pairings)
        let unpaired = RemoteHookRequest(
            token: "bad",
            deviceID: "vps-1",
            source: .claude,
            payload: .object(["hook_event_name": .string("UserPromptSubmit"), "prompt": .string("/nc remote")]),
            environment: [:],
            terminalSessionID: "w0t1:REMOTE"
        )
        XCTAssertFalse(processor.process(unpaired, now: now).response.ok)

        let code = try pairings.createCode(hostHint: "vps")
        let pairResponse = processor.pair(RemotePairRequest(code: code.code, deviceID: "vps-1", deviceName: "VPS"))
        let token = try XCTUnwrap(pairResponse.token)
        let paired = RemoteHookRequest(
            token: token,
            deviceID: "vps-1",
            source: .claude,
            payload: .object([
                "hook_event_name": .string("UserPromptSubmit"),
                "session_id": .string("remote-session"),
                "prompt": .string("/nc remote")
            ]),
            environment: ["PWD": "/srv/app"],
            sourceProcessID: 33,
            terminalSessionID: "w0t1:REMOTE"
        )
        let result = processor.process(paired, now: now)

        XCTAssertTrue(result.response.ok)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.kind, .connect)
        XCTAssertEqual(result.events.first?.name, "remote")
        XCTAssertEqual(result.events.first?.terminalSessionID, "w0t1:REMOTE")
        XCTAssertEqual(
            result.response.hookOutput,
            .object(["decision": .string("block"), "reason": .string("Noturcode connected \"remote\".")])
        )
    }

    func testRemoteSessionStartUsesTheNameChosenByNC() throws {
        let result = HookNormalizer.normalize(
            payload: .object([
                "hook_event_name": .string("SessionStart"),
                "session_id": .string("remote-named-session")
            ]),
            source: .codex,
            environment: [
                "PWD": "/root",
                "NOTURCODE_SESSION_NAME": "GPRC deploy"
            ],
            sourceProcessID: 44,
            terminalSessionIDOverride: "w0t1:REMOTE",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(result.events.first?.kind, .sessionStarted)
        XCTAssertEqual(result.events.first?.name, "GPRC deploy")
    }

    func testInteractiveNCIntegrationPreservesNetcatAndGuidesPairing() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shell = try String(contentsOf: repository.appendingPathComponent("Integrations/noturcode-shell.zsh"))
        let cli = try String(contentsOf: repository.appendingPathComponent("Integrations/noturcode-cli.zsh"))
        let agent = try String(contentsOf: repository.appendingPathComponent("Integrations/noturcode-agent.py"))

        XCTAssertTrue(shell.contains("nc()"))
        XCTAssertTrue(shell.contains("command /usr/bin/nc"))
        XCTAssertTrue(cli.contains("Pair a VPS"))
        XCTAssertTrue(cli.contains("Open an SSH workspace"))
        XCTAssertTrue(cli.contains("Resume an existing Codex chat"))
        XCTAssertTrue(cli.contains("Chat name"))
        XCTAssertTrue(agent.contains("codex\", \"resume\", \"--all"))
        XCTAssertTrue(cli.contains("noturcode-agent\\\" resume"))
        XCTAssertTrue(cli.contains("cleanup_workspace()"))
        XCTAssertTrue(cli.contains("local ssh_exit_code=$?"))
        XCTAssertTrue(cli.contains("return $?"))
        XCTAssertFalse(cli.contains("local status="))
        XCTAssertTrue(cli.contains("settle()"))
        XCTAssertTrue(cli.contains("[===>]"))
        XCTAssertTrue(cli.contains("StreamLocalBindUnlink=yes"))
        XCTAssertTrue(cli.contains("pair-code"))
        XCTAssertTrue(agent.contains("remotePair"))
        XCTAssertTrue(agent.contains("remoteHook"))
        XCTAssertTrue(agent.contains("NOTURCODE_SESSION_NAME"))
        XCTAssertTrue(agent.contains("Hooks must fail open"))
    }

    func testITermSelectionIntegrationUsesSelectionReferenceAndIsolatedClaudeRun() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integration = try String(contentsOf: repository.appendingPathComponent("Integrations/iterm2-ask-noturcode.py"))
        let panel = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SelectionQuestionController.swift"))

        XCTAssertTrue(integration.contains("ContextMenuProviderRPC"))
        XCTAssertTrue(integration.contains("Reference(\"selection\")"))
        XCTAssertTrue(integration.contains("ask-selection"))
        XCTAssertTrue(integration.contains("ro.noturcode.ask-selection"))
        XCTAssertTrue(integration.contains("selection-provider.log"))
        XCTAssertTrue(panel.contains("--no-session-persistence"))
        XCTAssertTrue(panel.contains("--safe-mode"))
        XCTAssertTrue(panel.contains("override var canBecomeKey: Bool { true }"))
        XCTAssertFalse(panel.contains("didAskAutomatically"))
        XCTAssertFalse(panel.contains(".task {"))
        XCTAssertTrue(panel.contains("Nothing is sent until you press Ask"))
    }

    func testAttentionBannersAreDismissedWhenTheSessionWorksAgain() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AnnouncementCoordinator.swift"))

        XCTAssertTrue(model.contains("transition.new?.state == .working || transition.new?.state == .idle"))
        XCTAssertTrue(model.contains("announcements.dismiss(sessionKey: key)"))
        XCTAssertTrue(coordinator.contains("queue.removeAll { $0.sessionKey == sessionKey }"))
    }

    func testInstallerStopsTheInstalledBundleByIdentifierBeforeReplacingIt() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let installer = try String(contentsOf: repository.appendingPathComponent("scripts/install.sh"))

        XCTAssertTrue(installer.contains("tell application id \"ro.noturcode.app\" to quit"))
        XCTAssertTrue(installer.contains("pgrep -x Noturcode >/dev/null || break"))
    }

    func testIntegrationSetupRequiresExplicitActionAndBacksUpReplacedFiles() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entry = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppEntry.swift"))
        let setup = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/IntegrationBootstrapper.swift"))
        let installer = try String(contentsOf: repository.appendingPathComponent("scripts/install.sh"))

        XCTAssertTrue(entry.contains("Set Up or Repair Integrations…"))
        XCTAssertFalse(entry.contains("installIfNeeded()"))
        XCTAssertTrue(setup.contains("Set up Noturcode integrations?"))
        XCTAssertTrue(setup.contains("backupExistingFile(destination"))
        XCTAssertTrue(setup.contains("backupDirectory: backup"))
        XCTAssertTrue(installer.contains("--integration-self-test \"$HOME\""))
        XCTAssertTrue(installer.contains("app-backups/$backup_stamp"))
    }

    func testFullIntegrationUninstallSupportsDryRunAndKeepsDataByDefault() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repository.appendingPathComponent("scripts/uninstall-integrations.sh")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-uninstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let configPaths = [".claude/settings.json", ".codex/hooks.json", ".gemini/settings.json"]
        let config = """
        {"hooks":{"Stop":[
          {"hooks":[
            {"type":"command","command":"echo keep"},
            {"type":"command","command":"\(home.path)/Library/Application Support/Noturcode/bin/noturcode-bridge hook"}
          ]}
        ]}}
        """
        for relative in configPaths {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(config.utf8).write(to: url)
        }

        let ownedFiles: [(String, String)] = [
            (".config/opencode/plugins/noturcode.js", "Generated by Noturcode\nnoturcode-bridge"),
            (".config/noturcode/shell.zsh", "Generated by Noturcode\ncommand /usr/bin/nc"),
            (".claude/skills/nc/SKILL.md", "name: nc\nNoturcode macOS notch tracker"),
            (".claude/skills/noturcode-summary/SKILL.md", "name: noturcode-summary\n# Noturcode summary"),
            (".codex/skills/noturcode-summary/SKILL.md", "name: noturcode-summary\n# Noturcode summary"),
            ("Library/Application Support/iTerm2/Scripts/AutoLaunch/Ask Noturcode.py", "ro.noturcode.ask-selection\nnoturcode-bridge"),
            ("Library/Application Support/Noturcode/bin/noturcode-cli", "Noturcode remote\nStreamLocalBindUnlink=yes"),
            ("Library/Application Support/Noturcode/remote/noturcode-agent.py", "Zero-dependency Noturcode helper\nHooks must fail open")
        ]
        for (relative, content) in ownedFiles {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let support = home.appendingPathComponent("Library/Application Support/Noturcode")
        let bridge = support.appendingPathComponent("bin/noturcode-bridge")
        let retainedState = support.appendingPathComponent("connected-sessions.json")
        try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bridge".utf8).write(to: bridge)
        try Data("[]".utf8).write(to: retainedState)
        let zshrc = home.appendingPathComponent(".zshrc")
        try Data("keep-this\n# Noturcode interactive CLI\n[[ -r \"$HOME/.config/noturcode/shell.zsh\" ]] && source \"$HOME/.config/noturcode/shell.zsh\"\n".utf8).write(to: zshrc)

        func run(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        let dryRun = try run(["--dry-run"])
        XCTAssertEqual(dryRun.0, 0, dryRun.1)
        XCTAssertTrue(dryRun.1.contains("would remove Noturcode hooks"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.path))

        let removal = try run([])
        XCTAssertEqual(removal.0, 0, removal.1)
        for relative in configPaths {
            let contents = try String(contentsOf: home.appendingPathComponent(relative))
            XCTAssertTrue(contents.contains("echo keep"))
            XCTAssertFalse(contents.contains("noturcode-bridge"))
        }
        for (relative, _) in ownedFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedState.path))
        let zshContents = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(zshContents.contains("keep-this"))
        XCTAssertFalse(zshContents.contains("Noturcode interactive CLI"))
        XCTAssertTrue(removal.1.contains("without stopping any terminal or harness session"))

        let dataRemoval = try run(["--delete-data"])
        XCTAssertEqual(dataRemoval.0, 0, dataRemoval.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testConversationMarkupSeparatesMarkdownCodeTablesAndASCIIDiagrams() {
        let source = """
        ## Result

        **Ready** for review.

        ```swift
        let answer = 42
        ```

        | Agent | State |
        | --- | --- |
        | root | working |

        ┌─────────┐
        │ prompt  │
        └────┬────┘
             ▼
        """

        let blocks = ConversationMarkupParser.parse(source)

        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[0], .markdown("## Result\n\n**Ready** for review."))
        XCTAssertEqual(blocks[1], .code(language: "swift", content: "let answer = 42"))
        XCTAssertEqual(blocks[2], .table("| Agent | State |\n| --- | --- |\n| root | working |"))
        XCTAssertEqual(blocks[3], .diagram("┌─────────┐\n│ prompt  │\n└────┬────┘\n     ▼"))
    }

    func testConversationMarkupKeepsUnclosedFenceAsCode() {
        XCTAssertEqual(
            ConversationMarkupParser.parse("Before\n\n```text\nA -> B"),
            [.markdown("Before"), .code(language: "text", content: "A -> B")]
        )
    }

    func testCodingHarnessDisplayNames() {
        XCTAssertEqual(AgentSource.claude.displayName, "Claude Code")
        XCTAssertEqual(AgentSource.codex.displayName, "Codex")
        XCTAssertEqual(AgentSource.gemini.displayName, "Gemini CLI")
        XCTAssertEqual(AgentSource.opencode.displayName, "OpenCode")
        XCTAssertEqual(AgentSource.grok.displayName, "Grok")
        XCTAssertEqual(AgentSource.harness.displayName, "Harness")
    }

    func testAvatarIdentityIsStableAndNormalized() {
        XCTAssertEqual(AvatarIdentity(name: "Noda Energy"), AvatarIdentity(name: "noda energy"))
        XCTAssertNotEqual(AvatarIdentity(name: "noda-energy").hue, AvatarIdentity(name: "bima-crm").hue)
        XCTAssertEqual(AvatarIdentity(name: "anything").saturation, 0.52)
    }

    func testActiveSubagentsBelongToCurrentPromptOnly() {
        let promptTime = Date(timeIntervalSince1970: 100)
        let session = TrackedSession(
            key: SessionKey(source: .claude, sessionID: "agents"),
            name: "agents",
            terminal: TerminalTarget(sessionID: "w0t1:AGENTS"),
            sourceProcessID: nil,
            cwd: nil,
            connectedAt: Date(timeIntervalSince1970: 1),
            lastPromptAt: promptTime,
            stateChangedAt: promptTime,
            subagents: [
                SubagentSnapshot(id: "old", type: "agent", state: .working, activity: "old", startedAt: .distantPast, updatedAt: promptTime.addingTimeInterval(-1)),
                SubagentSnapshot(id: "current", type: "agent", state: .working, activity: "current", startedAt: promptTime, updatedAt: promptTime.addingTimeInterval(1)),
                SubagentSnapshot(id: "done", type: "agent", state: .done, activity: "done", startedAt: promptTime, updatedAt: promptTime.addingTimeInterval(2))
            ]
        )

        XCTAssertEqual(session.activeSubagents.map(\.id), ["current"])
    }

    @MainActor
    func testSessionStoreBoundsFinishedSubagentsAndKeepsEveryActiveAgent() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-bounded-agents-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let store = SessionStore(persistence: SessionPersistence(fileURL: stateURL))
        let start = Date(timeIntervalSince1970: 100)
        _ = store.apply(BridgeEvent(
            kind: .connect,
            source: .claude,
            sessionID: "agents",
            timestamp: start,
            name: "agents",
            terminalSessionID: "w0t1:AGENTS"
        ))

        for index in 0..<50 {
            _ = store.apply(BridgeEvent(
                kind: .subagentCompleted,
                source: .claude,
                sessionID: "agents",
                timestamp: start.addingTimeInterval(Double(index + 1)),
                subagentID: "done-\(index)",
                subagentType: "worker"
            ))
        }
        for index in 0..<4 {
            _ = store.apply(BridgeEvent(
                kind: .subagentStarted,
                source: .claude,
                sessionID: "agents",
                timestamp: start.addingTimeInterval(Double(100 + index)),
                subagentID: "active-\(index)",
                subagentType: "worker"
            ))
        }

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.activeSubagents.count, 4)
        XCTAssertEqual(session.subagents.filter { $0.state == .done }.count, 32)
        XCTAssertEqual(session.subagents.count, 36)
        XCTAssertFalse(session.subagents.contains { $0.id == "done-0" })
        XCTAssertTrue(session.subagents.contains { $0.id == "done-49" })
    }

    @MainActor
    func testSessionStoreDropsAnIdenticalReconnectEvent() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-noop-event-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let store = SessionStore(persistence: SessionPersistence(fileURL: stateURL))
        let initial = BridgeEvent(
            kind: .connect,
            source: .claude,
            sessionID: "same",
            timestamp: Date(timeIntervalSince1970: 100),
            name: "same",
            terminalSessionID: "w0t1:SAME",
            sourceProcessID: 42,
            cwd: "/tmp/same"
        )
        XCTAssertNotNil(store.apply(initial))
        store.flushPersistenceForTesting()

        var transitionCount = 0
        store.transitionHandler = { _ in transitionCount += 1 }
        let duplicate = BridgeEvent(
            kind: .connect,
            source: .claude,
            sessionID: "same",
            timestamp: Date(timeIntervalSince1970: 200),
            name: "same",
            terminalSessionID: "w0t1:SAME",
            sourceProcessID: 42,
            cwd: "/tmp/same"
        )

        XCTAssertNil(store.apply(duplicate))
        XCTAssertEqual(transitionCount, 0)
    }

    func testDurationAndTokenFormatting() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(DurationFormatting.compact(from: start, to: start.addingTimeInterval(4_088)), "1h 8m")
        XCTAssertEqual(DurationFormatting.relative(from: start, to: start.addingTimeInterval(3)), "just now")
        XCTAssertEqual(DurationFormatting.tokens(286_000), "286k tok")
        XCTAssertEqual(DurationFormatting.tokens(1_250_000), "1.2M tok")
    }

    func testProviderFailurePresentationTurnsCompactionJSONIntoAChatMessage() throws {
        let raw = #"400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 1000841 tokens > 1000000 maximum"},"request_id":"req_private"}"#
        let presentation = try XCTUnwrap(ProviderFailurePresentation.parse(raw))

        XCTAssertEqual(presentation.title, "Context limit reached")
        XCTAssertTrue(presentation.message.contains("larger than the provider allows"))
        XCTAssertFalse(presentation.message.contains("req_private"))

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        XCTAssertTrue(views.contains("ProviderFailureCard(presentation:"))
        XCTAssertTrue(views.contains(".onChange(of: providerFailureEventID)"))
        let friendlyFailure = try XCTUnwrap(views.range(of: "if let providerFailure { return providerFailure.title }"))
        let rawFallback = try XCTUnwrap(views.range(of: "session.lastAgentMessage?.firstNonemptyLine ?? session.state.displayName"))
        XCTAssertLessThan(friendlyFailure.lowerBound, rawFallback.lowerBound)
    }

    func testTranscriptTokenCounterDeduplicatesClaudeAndUsesCodexCumulativeTotal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let claudeURL = directory.appendingPathComponent("claude.jsonl")
        let claudeLines = [
            #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":4,"cache_creation_input_tokens":3,"cache_read_input_tokens":20,"iterations":[{"input_tokens":999}]}}}"#,
            #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":4,"cache_creation_input_tokens":3,"cache_read_input_tokens":20}}}"#,
            #"{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":2,"output_tokens":6,"cache_creation_input_tokens":0,"cache_read_input_tokens":8}}}"#
        ].joined(separator: "\n")
        try Data(claudeLines.utf8).write(to: claudeURL)
        XCTAssertEqual(TranscriptTokenCounter.count(source: .claude, path: claudeURL.path), 53)

        let codexURL = directory.appendingPathComponent("codex.jsonl")
        let codexLines = [
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":245}}}}"#
        ].joined(separator: "\n")
        try Data(codexLines.utf8).write(to: codexURL)
        XCTAssertEqual(TranscriptTokenCounter.count(source: .codex, path: codexURL.path), 245)
    }

    func testClaudeTranscriptBecomesChatMessagesToolsAndImages() throws {
        let lines = [
            #"{"type":"user","timestamp":"2026-08-13T00:00:00Z","message":{"role":"user","content":"Fix this screen [Image #1] path=\"/tmp/reference.png\""}}"#,
            #"{"type":"assistant","timestamp":"2026-08-13T00:00:01Z","message":{"role":"assistant","model":"claude-opus-4-1","content":[{"type":"text","text":"I will inspect it."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"xcodebuild test"}}]}}"#,
            #"{"type":"user","timestamp":"2026-08-13T00:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"All tests passed"}]}}"#
        ].joined(separator: "\n")
        let entries = AgentTranscriptParser.parse(data: Data(lines.utf8), source: .claude)
        XCTAssertEqual(entries.map(\.kind), [.user, .assistant, .tool])
        XCTAssertEqual(entries[0].imagePaths, ["/tmp/reference.png"])
        XCTAssertEqual(entries[2].title, "Bash")
        XCTAssertTrue(entries[2].text.contains("xcodebuild test"))
        XCTAssertTrue(entries[2].detail?.contains("All tests passed") == true)
        XCTAssertEqual(entries[1].model, "claude-opus-4-1")
        XCTAssertEqual(entries[2].model, "claude-opus-4-1")
    }

    func testClaudeAssistantStringContentBecomesVisibleChatMessage() {
        let line = #"{"type":"assistant","timestamp":"2026-08-13T00:00:01Z","message":{"role":"assistant","model":"claude-opus-4-1","content":"Initial live marker"}}"#
        let entries = AgentTranscriptParser.parse(data: Data(line.utf8), source: .claude)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .assistant)
        XCTAssertEqual(entries.first?.text, "Initial live marker")
    }

    func testCodexTranscriptBecomesChatMessagesAndToolCalls() throws {
        let lines = [
            #"{"timestamp":"2026-08-13T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-08-13T00:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Make it smaller"}]}}"#,
            #"{"timestamp":"2026-08-13T00:00:01Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"xcodebuild test\"}","call_id":"c1"}}"#,
            #"{"timestamp":"2026-08-13T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Process exited with code 0"}}"#,
            #"{"timestamp":"2026-08-13T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#
        ].joined(separator: "\n")
        let entries = AgentTranscriptParser.parse(data: Data(lines.utf8), source: .codex)
        XCTAssertEqual(entries.map(\.kind), [.user, .tool, .assistant])
        XCTAssertEqual(entries[1].title, "Run command")
        XCTAssertTrue(entries[1].detail?.contains("code 0") == true)
        XCTAssertEqual(entries[1].model, "gpt-5.6-sol")
        XCTAssertEqual(entries[2].model, "gpt-5.6-sol")
    }

    func testCodexExecWrapperUsesNestedToolName() throws {
        let lines = [
            #"{"timestamp":"2026-08-13T00:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.apply_patch(\"*** Begin Patch\"); text(r);","call_id":"c1"}}"#,
            #"{"timestamp":"2026-08-13T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.view_image({path:\"/tmp/test.png\"}); image(r.image_url);","call_id":"c2"}}"#
        ].joined(separator: "\n")
        let entries = AgentTranscriptParser.parse(data: Data(lines.utf8), source: .codex)
        XCTAssertEqual(entries.map(\.title), ["Edit files", "Inspect image"])
    }

    func testToolHeavyCodexTailKeepsConversationMessages() throws {
        var lines = [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Keep this message"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Visible answer"}]}}"#
        ]
        for index in 0..<140 {
            lines.append(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"tools.exec_command({cmd: \"test \#(index)\"})","call_id":"c\#(index)"}}"#)
        }
        let entries = AgentTranscriptParser.parse(data: Data(lines.joined(separator: "\n").utf8), source: .codex)
        XCTAssertTrue(entries.contains { $0.kind == .user && $0.text == "Keep this message" })
        XCTAssertTrue(entries.contains { $0.kind == .assistant && $0.text == "Visible answer" })
    }

    func testNoturcodeSummaryContractRecognizesCompleteNaturalHandoff() {
        let mappedSummary = """
        Noturcode completion map
        ```text
        +----------+     +-----------+
        | FIXED UI | --> | VERIFIED  |
        +----------+     +-----------+
        ```
        Noturcode summary
        Done: [x] Fixed the animation -> [x] Verified the build
        Needs you: Nothing.
        """
        XCTAssertTrue(NoturcodeSummaryContract.isCompliant(mappedSummary))
        XCTAssertEqual(
            NoturcodeSummaryContract.completionMap(in: mappedSummary),
            "+----------+     +-----------+\n| FIXED UI | --> | VERIFIED  |\n+----------+     +-----------+"
        )
        XCTAssertFalse(NoturcodeSummaryContract.isCompliant("""
        Noturcode summary
        Done: [x] Fixed the animation -> [x] Verified the build
        Needs you: Nothing.
        """))
        XCTAssertFalse(NoturcodeSummaryContract.isCompliant("""
        Noturcode summary
        Done: Fixed and verified the animation.
        Needs you: Nothing.
        """))
        XCTAssertTrue(NoturcodeSummaryContract.isDisplayable("""
        Noturcode summary
        Done: Fixed and verified the animation.
        Needs you: Nothing.
        """))
        XCTAssertTrue(NoturcodeSummaryContract.instruction.contains("Noturcode completion map"))
        XCTAssertTrue(NoturcodeSummaryContract.instruction.contains("ASCII boxes, branches, and arrows"))
        XCTAssertTrue(NoturcodeSummaryContract.instruction.contains("at most 16 lines"))
        XCTAssertTrue(NoturcodeSummaryContract.instruction.contains("changed file or component"))
        XCTAssertTrue(NoturcodeSummaryContract.instruction.contains("exact verification result"))
        XCTAssertFalse(NoturcodeSummaryContract.isCompliant("Done with the animation."))
        XCTAssertTrue(NoturcodeSummaryContract.shouldInject(for: "Fix the animation"))
        XCTAssertFalse(NoturcodeSummaryContract.shouldInject(for: "/compact"))
        XCTAssertFalse(NoturcodeSummaryContract.shouldInject(for: "  /model gpt-5  "))
    }

    func testDoneAnnouncementHasNoDecorativeUnderline() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))
        let announcement = try XCTUnwrap(source.range(of: "struct AnnouncementView"))
        let body = String(source[announcement.lowerBound...])
        XCTAssertFalse(body.contains(".overlay(alignment: .bottom)"))
    }

    func testLiveChatKeepsDurableStateAndInteractiveControls() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let window = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/TerminalViewportWindowController.swift"))

        XCTAssertTrue(views.contains("private var visibleTranscriptEntries"))
        XCTAssertFalse(views.contains("case .missing:\n                    transcriptEntries = []"))
        XCTAssertTrue(views.contains("try await Task.sleep(for: .milliseconds(220))"))
        XCTAssertTrue(views.contains("selectedAgentConversationEntries"))
        XCTAssertTrue(views.contains("event.modifierFlags.contains(.option)"))
        XCTAssertTrue(window.contains("width: 760, height: 620"))
    }

    func testTranscriptLoadingPreservesLastValidConversation() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(views.contains("private var visibleTranscriptEntries"))
        XCTAssertTrue(views.contains("if entries != transcriptEntries,"))
        XCTAssertTrue(views.contains("!entries.isEmpty || transcriptEntries.isEmpty"))
        XCTAssertFalse(views.contains("case .missing:\n                    transcriptEntries = []"))
        XCTAssertFalse(views.contains("case let .failed(message):\n                    transcriptEntries = []"))
        XCTAssertTrue(views.contains("try await Task.sleep(for: .milliseconds(220))"))
        XCTAssertTrue(views.contains("session.transcriptPath ?? \"\""))
    }

    func testTranscriptReaderUsesIncrementalByteOffsetAndWindowUsesResizeSnapshot() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let reader = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AgentTranscriptReader.swift"))
        let window = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/TerminalViewportWindowController.swift"))

        XCTAssertTrue(reader.contains("var byteOffset: UInt64"))
        XCTAssertTrue(reader.contains("fileSize >= cached.byteOffset"))
        XCTAssertTrue(reader.contains("data(at: url, offset: cached.byteOffset)"))
        XCTAssertFalse(reader.contains("maximumBytes: 8_000_000"))
        XCTAssertTrue(window.contains("windowWillStartLiveResize"))
        XCTAssertTrue(window.contains("windowDidEndLiveResize"))
        XCTAssertTrue(window.contains("resizeState.snapshot"))
    }

    func testTranscriptEntryIDsStayStableWhenTheJSONLWindowMoves() {
        let records = [
            #"{"type":"assistant","uuid":"message-a","timestamp":"2026-08-13T10:00:00Z","message":{"content":"First","model":"claude-opus-4-1"}}"#,
            #"{"type":"assistant","timestamp":"2026-08-13T10:00:01Z","message":{"content":"Second","model":"claude-opus-4-1"}}"#
        ]
        let leadingRecord = #"{"type":"system","timestamp":"2026-08-13T09:59:00Z","message":{"content":"ignored"}}"#
        let original = AgentTranscriptParser.parse(data: Data(records.joined(separator: "\n").utf8), source: .claude)
        let shifted = AgentTranscriptParser.parse(data: Data(([leadingRecord] + records).joined(separator: "\n").utf8), source: .claude)

        XCTAssertEqual(original.map(\.id), shifted.map(\.id))
        XCTAssertEqual(original.map(\.text), ["First", "Second"])
    }

    func testUnreadCompletionIsPersistentAndClearedByOpeningChat() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(model.contains("final class CompletionReadStore"))
        XCTAssertTrue(model.contains("seenCompletionTimes"))
        XCTAssertTrue(model.contains("completionReads.markSeen(session)"))
        XCTAssertTrue(views.contains("completionReads.isUnread(session)"))
        XCTAssertTrue(views.contains("unread-completion-"))
    }

    func testCollapsedPillReflectsPersistentUnreadCompletionState() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notch = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))

        XCTAssertTrue(notch.contains("completionReads: model.completionReads"))
        XCTAssertTrue(notch.contains("completionReads.isUnread(session)"))
        XCTAssertTrue(notch.contains("completionIsUnread: completionReads.isUnread(session)"))
        XCTAssertFalse(notch.contains("CollapsedCompletionOutline"))
    }

    func testEveryNativeBrandMarkUsesTheCurrentApplicationIcon() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(views.contains("NSApplication.shared.applicationIconImage"))
        XCTAssertTrue(views.contains("Image(nsImage: appIcon)"))
        XCTAssertFalse(views.contains("private struct NoturcodeGlyph"))
    }

    func testCompletionMarblesKeepOneDiameterAndOnlyChangeOutlineColor() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(views.contains("let completionIsUnread: Bool?"))
        XCTAssertTrue(views.contains("lineWidth: max(1.15, size * 0.075)"))
        XCTAssertTrue(views.contains(".animation(reduceMotion ? nil : .smooth(duration: 0.24), value: completionIsUnread)"))
    }

    func testSessionMarbleUsesColoredThinkingOrbMotionsInsideNativeStateRing() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let orb = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ThinkingOrbLayerView.swift"))

        XCTAssertTrue(orb.contains("struct ColoredThinkingOrb: NSViewRepresentable"))
        XCTAssertTrue(views.contains("case .working, .askingYou: .composing"))
        XCTAssertTrue(views.contains("case .done: .breathing"))
        XCTAssertTrue(views.contains("&& animate\n            && size >= 12"))
        XCTAssertTrue(views.contains("state == .working || state == .askingYou || state == .done"))
        XCTAssertTrue(views.contains("primaryHue: identity.hue"))
        XCTAssertTrue(views.contains("secondaryHue: identity.secondaryHue"))
        XCTAssertTrue(views.contains("stateRing(time:"))
        XCTAssertFalse(views.contains("private var marbleSurface"))
    }

    func testResidentThinkingOrbUsesCoreAnimationInsteadOfSwiftUITimelineFrames() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let orb = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ThinkingOrbLayerView.swift"))

        XCTAssertTrue(orb.contains("NSViewRepresentable"))
        XCTAssertTrue(orb.contains("CAKeyframeAnimation(keyPath: \"contents\")"))
        XCTAssertTrue(orb.contains("layer.add(animation, forKey: Self.animationKey)"))
        XCTAssertTrue(orb.contains("accessibilityDisplayShouldReduceMotion"))
        XCTAssertFalse(orb.contains("TimelineView"))
        XCTAssertFalse(orb.contains("Canvas("))
    }

    func testAttentionAnnouncementUsesOneCursorAnchoredFloatingPanel() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))

        XCTAssertTrue(coordinator.contains("AttentionAnnouncementPanelController"))
        XCTAssertTrue(coordinator.contains("NSEvent.mouseLocation"))
        XCTAssertTrue(coordinator.contains("AnnouncementPlacement.origin"))

        let screen = CGRect(x: 1_000, y: -900, width: 1_920, height: 1_080)
        let visible = CGRect(x: 1_000, y: -876, width: 1_920, height: 1_032)
        let size = CGSize(width: 392, height: 96)
        let bottom = AnnouncementPlacement.origin(
            cursor: CGPoint(x: 1_100, y: -800),
            screenFrame: screen,
            visibleFrame: visible,
            size: size
        )
        let top = AnnouncementPlacement.origin(
            cursor: CGPoint(x: 2_850, y: 100),
            screenFrame: screen,
            visibleFrame: visible,
            size: size
        )

        XCTAssertEqual(bottom, CGPoint(x: 1_022, y: -834))
        XCTAssertEqual(top, CGPoint(x: 2_506, y: 30))
    }

    func testAttentionBannerClickFocusesItsITermSession() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let notch = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))

        XCTAssertTrue(coordinator.contains("AttentionAnnouncementPanelController { [weak model] sessionKey in"))
        XCTAssertTrue(coordinator.contains("model.jump(to: session)"))
        XCTAssertTrue(coordinator.contains("model.announcements.dismiss(sessionKey: sessionKey)"))
        XCTAssertTrue(coordinator.contains("hostingView.onClick = { [weak self] in"))
        XCTAssertTrue(coordinator.contains("AnnouncementView(announcement: announcement)"))
        XCTAssertTrue(coordinator.contains("NSClickGestureRecognizer(target: self"))
        XCTAssertTrue(coordinator.contains("override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }"))
        XCTAssertTrue(notch.contains(".accessibilityHint(\"Focus this session in iTerm2\")"))
    }

    func testAttentionBannerHasComfortableVerticalPadding() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let notch = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))

        XCTAssertTrue(coordinator.contains("CGSize(width: 408, height: 106)"))
        XCTAssertTrue(notch.contains(".padding(.vertical, 15)"))
    }

    func testAttentionBannerUsesAControlledTwoStagePopAndAudibleFinishCue() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let sounds = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NoturcodeSoundPlayer.swift"))

        XCTAssertTrue(coordinator.contains("let overshootFrame"))
        XCTAssertTrue(coordinator.contains("self.presentedID == announcement.id"))
        XCTAssertTrue(coordinator.contains("context.duration = 0.16"))
        XCTAssertTrue(coordinator.contains("settleContext.duration = 0.10"))
        XCTAssertTrue(sounds.contains("sound.volume = 0.82"))
    }

    func testDesktopSidebarWrapsBehindTheRoundedApplicationShell() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let status = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/StatusWindowController.swift"))

        XCTAssertTrue(status.contains("private var applicationShell"))
        XCTAssertTrue(status.contains("HStack(spacing: -14)"))
        XCTAssertTrue(status.contains("RoundedRectangle(cornerRadius: 16, style: .continuous)"))
        XCTAssertTrue(status.contains("Color(red: 0.020, green: 0.022, blue: 0.028)"))
        XCTAssertTrue(status.contains(".stroke(.white.opacity(0.13), lineWidth: 0.8)"))
        XCTAssertTrue(status.contains(".frame(width: 272)"))
        XCTAssertTrue(status.contains(".frame(width: 286, alignment: .leading)"))
        XCTAssertTrue(status.contains(".zIndex(1)"))
        XCTAssertFalse(status.contains("Rectangle().fill(.white.opacity(0.075)).frame(width: 1)"))
    }

    func testDesktopConversationChromeUsesBalancedPaddingAndInteractiveControls() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let status = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/StatusWindowController.swift"))
        let sessions = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(status.contains("private struct DesktopHeaderControl"))
        XCTAssertTrue(status.contains("private struct ShellPressButtonStyle"))
        XCTAssertTrue(status.contains(".padding(.top, 22)"))
        XCTAssertTrue(status.contains(".padding(.bottom, 8)"))
        XCTAssertFalse(status.contains(".padding(.top, 25)"))
        XCTAssertTrue(status.contains("reduceMotion ? .easeOut(duration: 0.08) : .smooth(duration: 0.20)"))

        XCTAssertTrue(sessions.contains("Label(conversationTitle, systemImage: \"bubble.left.and.bubble.right\")"))
        XCTAssertTrue(sessions.contains("private struct ConversationSidebarToggle"))
        XCTAssertTrue(sessions.contains(".frame(height: presentation == .desktop ? 30 : nil)"))
        XCTAssertTrue(sessions.contains(".padding(.horizontal, presentation == .desktop ? 8 : 0)"))
        XCTAssertTrue(sessions.contains("reduceMotion ? nil : .smooth(duration: 0.20)"))
    }

    func testSocketAcknowledgementWaitsForSessionPersistence() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))
        let bridge = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeBridge/main.swift"))

        XCTAssertFalse(appModel.contains("DispatchSemaphore"))
        XCTAssertTrue(appModel.contains("Task { @MainActor in\n                self?.receive(envelope.event)"))
        XCTAssertTrue(appModel.contains("return Data(\"{\\\"ok\\\":true}\".utf8)"))
        XCTAssertTrue(appModel.contains("return Data(\"{\\\"ok\\\":true}\".utf8)"))
        XCTAssertTrue(bridge.contains("guard responseAcknowledgesPersistence(response)"))
        XCTAssertTrue(bridge.contains("private static func responseAcknowledgesPersistence"))
    }

    func testAppDisconnectRemovesOnlyNoturcodeTracking() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let start = try XCTUnwrap(model.range(of: "func disconnectFromNoturcode(_ session: TrackedSession)"))
        let tail = String(model[start.lowerBound...])
        let end = try XCTUnwrap(tail.range(of: "\n    }"))
        let body = String(tail[..<end.upperBound])

        XCTAssertTrue(body.contains("processMonitor?.unwatch(key: session.key)"))
        XCTAssertTrue(body.contains("store.remove(session.key)"))
        XCTAssertTrue(body.contains("announcements.dismiss(sessionKey: session.key)"))
        XCTAssertFalse(body.contains("navigator.reveal"))
        XCTAssertFalse(body.contains("promptSender"))
        XCTAssertFalse(body.contains("kill("))
        XCTAssertFalse(body.contains("terminate"))
        XCTAssertTrue(views.contains("Disconnect from Noturcode"))
        XCTAssertTrue(views.contains("disconnect-noturcode-"))
    }

    func testHardwareNotchReservesItsFullHeightAboveOneSessionRail() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notch = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))

        XCTAssertTrue(notch.contains("return metrics.collapsedHeight(sessionCount: store.sessions.count)"))
        XCTAssertTrue(notch.contains(".padding(.top, metrics.dockContentTopInset)"))
        XCTAssertTrue(notch.contains("sessionStrip(sessions)"))
        XCTAssertFalse(notch.contains("sessionStrip(working)"))
        XCTAssertFalse(notch.contains("sessionStrip(attention)"))
        XCTAssertFalse(notch.contains("Color.clear.frame(width: metrics.neckWidth"))
        XCTAssertTrue(coordinator.contains("func dockRailHeight(sessionCount: Int) -> CGFloat"))
        XCTAssertTrue(coordinator.contains("return minimumDockRailHeight"))
        XCTAssertTrue(coordinator.contains("func compactItemCount(sessionCount: Int) -> Int"))
        XCTAssertTrue(coordinator.contains("min(3, sessionCount) + (sessionCount > 3 ? 1 : 0)"))
        XCTAssertTrue(coordinator.contains("var notchShoulderClearance: CGFloat { hasHardwareNotch ? 4 : 0 }"))
        XCTAssertTrue(coordinator.contains("neckHeight + notchShoulderClearance"))
        XCTAssertTrue(coordinator.contains("func collapsedHeight(sessionCount: Int) -> CGFloat"))
        XCTAssertTrue(coordinator.contains("height = metrics.collapsedHeight(sessionCount: sessionCount)"))
    }

    func testHardwareSurfaceAlwaysFillsTheTopShoulders() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notch = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))

        XCTAssertTrue(notch.contains("topShoulderFill: 1"))
        XCTAssertFalse(notch.contains("topShoulderFill: state.isExpanded ? 1 : 0"))
        XCTAssertTrue(notch.contains("let topLeft = neckLeft + (rect.minX - neckLeft) * topShoulderFill"))
        XCTAssertTrue(notch.contains("let topRight = neckRight + (rect.maxX - neckRight) * topShoulderFill"))
    }

    func testWorkflowAgentSelectionLoadsItsOwnConversation() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let reader = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AgentTranscriptReader.swift"))

        XCTAssertTrue(views.contains("selectedAgentConversationEntries"))
        XCTAssertTrue(views.contains("reader.snapshot(session, subagentID: subagentID)"))
        XCTAssertTrue(views.contains("displayedTranscriptEntries"))
        XCTAssertTrue(views.contains("workflow-node-" + "\\(node.id)"))
        XCTAssertTrue(reader.contains("func snapshot(_ session: TrackedSession, subagentID: String)"))
        XCTAssertTrue(reader.contains("parentURL.deletingPathExtension()"))
        XCTAssertTrue(reader.contains("subagents/agent-" + "\\(normalizedID).jsonl"))
    }

    func testWorkingSpinnerIsDrivenBySessionStateInsteadOfHover() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(views.contains("state == .working"))
        XCTAssertTrue(views.contains("isAnimated: !reduceMotion"))
        XCTAssertTrue(views.contains("CABasicAnimation(keyPath: \"transform.rotation.z\")"))
        XCTAssertTrue(views.contains("rotation.toValue = -Double.pi * 5 / 2"))
        XCTAssertTrue(views.contains("rotation.repeatCount = .infinity"))
        XCTAssertFalse(views.contains("private var animatesState"))
        XCTAssertFalse(views.contains("ShaderLibrary.fluidMarble"))
    }

    func testImagePasteShortcutsAndASCIIPreviewAreRoutedAtTheAppKitBoundary() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(views.contains("override func performKeyEquivalent(with event: NSEvent) -> Bool"))
        XCTAssertTrue(views.contains("isImagePasteShortcut(event)"))
        XCTAssertTrue(views.contains("event.modifierFlags.contains(.option)"))
        XCTAssertTrue(views.contains("accessibilityIdentifier(\"prompt-image-attachment\")"))
        XCTAssertTrue(views.contains("private var completionMapWidth: CGFloat"))
        XCTAssertFalse(views.contains("if let completionMap {\n                ScrollView(.horizontal)"))
    }

    func testPromptTimelineUsesFullConversationHeightAndUnclippedPopover() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(views.contains("private struct PromptTimeline: View"))
        XCTAssertTrue(views.contains("GeometryReader { geometry in"))
        XCTAssertTrue(views.contains("let markerDiameter: CGFloat = 26"))
        XCTAssertTrue(views.contains("geometry.size.height - markerDiameter"))
        XCTAssertTrue(views.contains("railInset + progress * usableHeight"))
        XCTAssertTrue(views.contains("private struct PromptTimelineMarker: View"))
        let markerStart = try XCTUnwrap(views.range(of: "private struct PromptTimelineMarker: View"))
        let previewStart = try XCTUnwrap(views.range(of: "private struct PromptRailPreview: View"))
        let marker = String(views[markerStart.lowerBound..<previewStart.lowerBound])
        XCTAssertTrue(marker.contains(".fill(.white.opacity(isLatest ? 0.82 : 0.30))"))
        XCTAssertFalse(marker.contains(".cyan"))
        XCTAssertTrue(views.contains(".popover(isPresented: $isPreviewPresented"))
        XCTAssertTrue(views.contains("try await Task.sleep(for: .milliseconds(280))"))
        XCTAssertTrue(views.contains("guard !isPointerOverPreview else { return }"))
        XCTAssertTrue(views.contains("onSelect(entry)"))
        XCTAssertFalse(views.contains("let markerStride: CGFloat = 26"))
    }

    func testNCCommandParsesArbitraryNamesAndStop() {
        XCTAssertEqual(NCCommand.parse(prompt: "/nc powergrid landing rework"), .connect("powergrid landing rework"))
        XCTAssertEqual(NCCommand.parse(prompt: "NOTURCODE_CONNECT powergrid landing rework"), .connect("powergrid landing rework"))
        XCTAssertEqual(NCCommand.parse(prompt: "NOTURCODE_CONNECT stop"), .stop)
        XCTAssertEqual(NCCommand.parse(prompt: "nc powergrid landing rework"), .connect("powergrid landing rework"))
        XCTAssertEqual(NCCommand.parse(prompt: "NC stop"), .stop)
        XCTAssertEqual(NCCommand.parse(prompt: " /nc stop\n"), .stop)
        XCTAssertEqual(NCCommand.parse(prompt: "/nc"), .invalid("Type /nc followed by a session name."))
        XCTAssertNil(NCCommand.parse(prompt: "please /nc project"))
    }

    func testConnectNormalizationUsesExactSessionAndTerminal() throws {
        let payload = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"thr_123","cwd":"/work","prompt":"/nc alpha beta"}"#.utf8)
        let result = try HookNormalizer.normalize(
            payload: payload,
            source: .codex,
            environment: ["TERM_SESSION_ID": "w0t1p2:ABC-123"],
            sourceProcessID: 42,
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].kind, .connect)
        XCTAssertEqual(result.events[0].sessionID, "thr_123")
        XCTAssertEqual(result.events[0].terminalSessionID, "w0t1p2:ABC-123")
        XCTAssertEqual(result.events[0].name, "alpha beta")
        XCTAssertTrue(result.commandResult?.shouldBlockPrompt == true)
    }

    func testConnectNormalizationSupportsGenericTerminals() throws {
        let payload = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"gem-1","prompt":"/nc portable"}"#.utf8)
        let result = try HookNormalizer.normalize(
            payload: payload,
            source: .gemini,
            environment: ["TERM_PROGRAM": "Apple_Terminal", "TTY": "/dev/ttys004"],
            sourceProcessID: 17,
            now: .distantPast
        )
        XCTAssertEqual(result.events.first?.kind, .connect)
        XCTAssertEqual(result.events.first?.terminalSessionID, "terminal:Apple_Terminal:/dev/ttys004")
    }

    func testGeminiToolHooksNormalizeToSharedActivityEvents() throws {
        let before = Data(#"{"hook_event_name":"BeforeTool","session_id":"gem-1","tool_name":"run_shell_command","tool_input":{"command":"pnpm test"}}"#.utf8)
        let after = Data(#"{"hook_event_name":"AfterTool","session_id":"gem-1","tool_name":"run_shell_command","tool_input":{"command":"pnpm test"}}"#.utf8)
        XCTAssertEqual(try HookNormalizer.normalize(payload: before, source: .gemini,
                                                     environment: [:], sourceProcessID: 2).events.first?.kind,
                       .activityStarted)
        XCTAssertEqual(try HookNormalizer.normalize(payload: after, source: .gemini,
                                                     environment: [:], sourceProcessID: 2).events.first?.kind,
                       .activityFinished)
    }

    func testGeminiBeforeAgentConnectsAndTracksNormalPrompts() throws {
        let connect = Data(#"{"hook_event_name":"BeforeAgent","session_id":"gem-2","prompt":"/nc gemini work"}"#.utf8)
        let connected = try HookNormalizer.normalize(payload: connect, source: .gemini,
                                                      environment: ["TERM_PROGRAM": "Apple_Terminal", "TTY": "/dev/ttys008"],
                                                      sourceProcessID: 4)
        XCTAssertEqual(connected.events.first?.kind, .connect)
        XCTAssertEqual(connected.events.first?.name, "gemini work")

        let prompt = Data(#"{"hook_event_name":"BeforeAgent","session_id":"gem-2","prompt":"Fix the tests"}"#.utf8)
        let tracked = try HookNormalizer.normalize(payload: prompt, source: .gemini,
                                                    environment: [:], sourceProcessID: 4)
        XCTAssertEqual(tracked.events.first?.kind, .promptSubmitted)
        XCTAssertEqual(tracked.events.first?.prompt, "Fix the tests")
    }

    func testOnlyExplicitQuestionToolsBecomeAsking() throws {
        func kind(for tool: String) throws -> BridgeEventKind? {
            let payload = Data("{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s\",\"tool_name\":\"\(tool)\"}".utf8)
            return try HookNormalizer.normalize(
                payload: payload,
                source: .claude,
                environment: [:],
                sourceProcessID: 7,
                now: .distantPast
            ).events.first?.kind
        }
        XCTAssertEqual(try kind(for: "AskUserQuestion"), .askingYou)
        XCTAssertEqual(try kind(for: "request_user_input"), .askingYou)
        XCTAssertEqual(try kind(for: "Bash"), .activityStarted)
    }

    func testClaudeToolCallsShowCommandAndKeepItAfterCompletion() throws {
        let started = Data(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"pnpm test\n-- --runInBand"}}"#.utf8)
        let finished = Data(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"pnpm test\n-- --runInBand"}}"#.utf8)

        let startedEvent = try XCTUnwrap(HookNormalizer.normalize(
            payload: started, source: .claude, environment: [:], sourceProcessID: 7, now: .distantPast
        ).events.first)
        let finishedEvent = try XCTUnwrap(HookNormalizer.normalize(
            payload: finished, source: .claude, environment: [:], sourceProcessID: 7, now: .distantPast
        ).events.first)

        XCTAssertEqual(startedEvent.activity, "Bash · pnpm test -- --runInBand")
        XCTAssertEqual(finishedEvent.activity, "Finished · Bash · pnpm test -- --runInBand")
    }

    func testToolCallsShowFileAndSearchDetails() throws {
        func activity(tool: String, input: String) throws -> String? {
            let payload = Data("{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s\",\"tool_name\":\"\(tool)\",\"tool_input\":\(input)}".utf8)
            return try HookNormalizer.normalize(
                payload: payload, source: .claude, environment: [:], sourceProcessID: 7, now: .distantPast
            ).events.first?.activity
        }

        XCTAssertEqual(try activity(tool: "Read", input: #"{"file_path":"Sources/App.swift"}"#), "Read · Sources/App.swift")
        XCTAssertEqual(try activity(tool: "Grep", input: #"{"pattern":"currentActivity"}"#), "Grep · currentActivity")
    }

    @MainActor
    func testSessionStoreKeepsBoundedRecentCodexToolCallsWithoutFinishedDuplicates() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-tool-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let store = SessionStore(persistence: SessionPersistence(fileURL: stateURL))
        let start = Date(timeIntervalSince1970: 100)
        _ = store.apply(BridgeEvent(
            kind: .connect,
            source: .codex,
            sessionID: "tools",
            timestamp: start,
            name: "codex-tools",
            terminalSessionID: "w0t1:TOOLS"
        ))
        for index in 0..<14 {
            _ = store.apply(BridgeEvent(
                kind: .activityStarted,
                source: .codex,
                sessionID: "tools",
                timestamp: start.addingTimeInterval(Double(index + 1)),
                activity: "Command \(index)"
            ))
            _ = store.apply(BridgeEvent(
                kind: .activityFinished,
                source: .codex,
                sessionID: "tools",
                timestamp: start.addingTimeInterval(Double(index + 1) + 0.5),
                activity: "Finished · Command \(index)"
            ))
        }

        let activities = try XCTUnwrap(store.sessions.first?.recentActivities)
        XCTAssertEqual(activities.count, 10)
        XCTAssertEqual(activities.first?.label, "Command 4")
        XCTAssertEqual(activities.last?.label, "Command 13")
        XCTAssertFalse(activities.contains { $0.label.hasPrefix("Finished") })
    }

    func testSensitiveToolArgumentsAreNeverDisplayed() throws {
        let secretFixture = ["private", "value"].joined(separator: "-")
        let payload = Data("{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"curl -H 'Authorization: Bearer \(secretFixture)' example.test\"}}".utf8)
        let event = try XCTUnwrap(HookNormalizer.normalize(
            payload: payload, source: .claude, environment: [:], sourceProcessID: 7, now: .distantPast
        ).events.first)
        XCTAssertEqual(event.activity, "Bash · sensitive arguments hidden")
        XCTAssertFalse(try XCTUnwrap(event.activity).contains(secretFixture))
    }

    @MainActor
    func testSessionStoreTracksOnlyConnectedSessionsAndSortsByPromptRecency() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(persistence: SessionPersistence(fileURL: directory.appendingPathComponent("sessions.json")))
        let t0 = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(store.apply(BridgeEvent(kind: .promptSubmitted, source: .codex, sessionID: "not-connected", timestamp: t0)))
        XCTAssertTrue(store.sessions.isEmpty)

        _ = store.apply(BridgeEvent(kind: .connect, source: .codex, sessionID: "one", timestamp: t0, name: "one", terminalSessionID: "w0t1:ONE"))
        _ = store.apply(BridgeEvent(kind: .connect, source: .claude, sessionID: "two", timestamp: t0.addingTimeInterval(1), name: "two", terminalSessionID: "w0t2:TWO"))
        _ = store.apply(BridgeEvent(kind: .promptSubmitted, source: .codex, sessionID: "one", timestamp: t0.addingTimeInterval(2)))

        XCTAssertEqual(store.sessions.map(\.name), ["one", "two"])
        XCTAssertEqual(store.sessions[0].state, .working)

        _ = store.apply(BridgeEvent(kind: .responseCompleted, source: .codex, sessionID: "one", timestamp: t0.addingTimeInterval(3), message: "finished"))
        XCTAssertEqual(store.sessions[0].state, .done)
        XCTAssertEqual(store.sessions[0].lastAgentMessage, "finished")

        _ = store.apply(BridgeEvent(kind: .activityFinished, source: .codex, sessionID: "one", timestamp: t0.addingTimeInterval(3.5), sessionTokens: 42_000))
        XCTAssertEqual(store.sessions[0].tokens, 42_000)

        _ = store.apply(BridgeEvent(kind: .disconnect, source: .codex, sessionID: "one", timestamp: t0.addingTimeInterval(4)))
        XCTAssertEqual(store.sessions.map(\.name), ["two"])
    }

    @MainActor
    func testReconnectPreservesPromptRecency() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(persistence: SessionPersistence(fileURL: directory.appendingPathComponent("sessions.json")))
        let firstPrompt = Date(timeIntervalSince1970: 1_000)
        let reconnect = Date(timeIntervalSince1970: 9_000)

        _ = store.apply(BridgeEvent(
            kind: .connect,
            source: .opencode,
            sessionID: "stable-order",
            timestamp: firstPrompt,
            name: "OpenCode",
            nativeSession: NativeSessionConnection(
                transport: .openCodeServer,
                conversationID: "stable-order",
                endpoint: "http://127.0.0.1:4096"
            )
        ))
        _ = store.apply(BridgeEvent(
            kind: .connect,
            source: .opencode,
            sessionID: "stable-order",
            timestamp: reconnect,
            name: "OpenCode",
            nativeSession: NativeSessionConnection(
                transport: .openCodeServer,
                conversationID: "stable-order",
                endpoint: "http://127.0.0.1:4096"
            )
        ))

        XCTAssertEqual(store.sessions.first?.lastPromptAt, firstPrompt)
    }

    func testOpenCodeTranscriptDiscoveryNeverFallsBackToAnUnrelatedDatabase() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AgentTranscriptReader.swift"))
        let start = try XCTUnwrap(source.range(of: "private func findOpenCodeDatabase"))
        let end = try XCTUnwrap(source.range(of: "\n    private func openCodeDatabaseURLs", range: start.lowerBound..<source.endIndex))
        let finder = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(finder.contains("return nil"))
        XCTAssertFalse(finder.contains(".first(where:"))
    }

    func testZellijAdapterTargetsTheRecordedSessionAndPane() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let navigator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermNavigator.swift"))
        let sender = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermPromptSender.swift"))

        XCTAssertTrue(navigator.contains("revealZellij(identity, started: started)"))
        XCTAssertTrue(navigator.contains("[\"--session\", session, \"action\", \"focus-pane-id\", pane]"))
        XCTAssertTrue(sender.contains("sendToZellij(prompt, identity: identity)"))
        XCTAssertTrue(sender.contains("[\"--session\", session, \"action\", \"paste\", \"--pane-id\", pane, prompt]"))
        XCTAssertTrue(sender.contains("[\"--session\", session, \"action\", \"send-keys\", \"--pane-id\", pane, \"Enter\"]"))
        XCTAssertFalse(navigator.contains("Zellij did not provide a safe focus command"))
        XCTAssertFalse(sender.contains("Zellij did not provide a safe send command"))
    }

    @MainActor
    func testSessionStartAutoConnectsARealTerminalWithoutNCCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(persistence: SessionPersistence(fileURL: directory.appendingPathComponent("sessions.json")))
        let started = Date(timeIntervalSince1970: 2_000)

        let transition = store.apply(BridgeEvent(
            kind: .sessionStarted,
            source: .claude,
            sessionID: "auto-session",
            timestamp: started,
            terminalSessionID: "w0t2:AUTO",
            sourceProcessID: 442,
            cwd: "/tmp/Power Grid",
            transcriptPath: "/tmp/auto-session.jsonl"
        ))

        let session = try XCTUnwrap(transition?.new)
        XCTAssertEqual(session.name, "Power Grid")
        XCTAssertEqual(session.terminal?.sessionID, "w0t2:AUTO")
        XCTAssertEqual(session.sourceProcessID, 442)
        XCTAssertEqual(session.transcriptPath, "/tmp/auto-session.jsonl")
        XCTAssertEqual(session.state, .idle)
    }

    @MainActor
    func testNamedRemoteSessionReplacesTheRootDirectoryFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(persistence: SessionPersistence(fileURL: directory.appendingPathComponent("sessions.json")))
        _ = store.apply(BridgeEvent(
            kind: .sessionStarted,
            source: .codex,
            sessionID: "remote-existing",
            terminalSessionID: "w0t2:REMOTE",
            cwd: "/root"
        ))
        let renamed = store.apply(BridgeEvent(
            kind: .sessionStarted,
            source: .codex,
            sessionID: "remote-existing",
            name: "GPRC deploy",
            terminalSessionID: "w0t2:REMOTE",
            cwd: "/root"
        ))

        XCTAssertEqual(renamed?.new?.name, "GPRC deploy")
    }

    @MainActor
    func testSessionStoreAcceptsAndPersistsNativeSessionWithoutTerminal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("sessions.json")
        let persistence = SessionPersistence(fileURL: fileURL)
        let store = SessionStore(persistence: persistence)
        let native = NativeSessionConnection(
            transport: .codexAppServer,
            conversationID: "thread-native-1"
        )

        let transition = store.apply(BridgeEvent(
            kind: .connect,
            source: .codex,
            sessionID: "thread-native-1",
            name: "Native Codex",
            nativeSession: native,
            cwd: "/tmp/native-project"
        ))
        store.flushPersistenceForTesting()

        XCTAssertNotNil(transition)
        XCTAssertNil(store.sessions.first?.terminal)
        XCTAssertEqual(store.sessions.first?.nativeSession, native)
        XCTAssertEqual(persistence.load().first?.nativeSession, native)
    }

    @MainActor
    func testSessionStoreUsesOnlyFirstNonEmptyLineOfConnectionName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(persistence: SessionPersistence(fileURL: directory.appendingPathComponent("sessions.json")))

        _ = store.apply(BridgeEvent(
            kind: .connect,
            source: .codex,
            sessionID: "multiline-name",
            timestamp: Date(timeIntervalSince1970: 1_000),
            name: "  nc  \nthis is prompt text, not the session name",
            terminalSessionID: "w0t1:NAME"
        ))

        XCTAssertEqual(store.sessions.first?.name, "nc")
    }

    @MainActor
    func testHarnessSessionEndDoesNotRemoveExplicitConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = SessionPersistence(fileURL: directory.appendingPathComponent("sessions.json"))
        let store = SessionStore(persistence: persistence)
        let key = SessionKey(source: .claude, sessionID: "resumable")
        let connected = BridgeEvent(
            kind: .connect,
            source: key.source,
            sessionID: key.sessionID,
            timestamp: Date(timeIntervalSince1970: 10),
            name: "noda-blog",
            terminalSessionID: "w0t1p2:KEEP-ME",
            sourceProcessID: 83420,
            cwd: "/work"
        )
        _ = store.apply(connected)
        _ = store.apply(BridgeEvent(
            kind: .activityStarted,
            source: key.source,
            sessionID: key.sessionID,
            timestamp: Date(timeIntervalSince1970: 11),
            activity: "working"
        ))

        _ = store.apply(BridgeEvent(
            kind: .sessionEnded,
            source: key.source,
            sessionID: key.sessionID,
            timestamp: Date(timeIntervalSince1970: 12)
        ))

        let retained = try XCTUnwrap(store.sessions.first(where: { $0.key == key }))
        XCTAssertEqual(retained.name, "noda-blog")
        XCTAssertEqual(retained.state, .idle)
        XCTAssertNil(retained.sourceProcessID)
        XCTAssertNil(retained.currentActivity)
        store.flushPersistenceForTesting()
        XCTAssertEqual(SessionPersistence(fileURL: persistence.fileURL).load().map(\.name), ["noda-blog"])

        _ = store.apply(BridgeEvent(
            kind: .disconnect,
            source: key.source,
            sessionID: key.sessionID,
            timestamp: Date(timeIntervalSince1970: 13)
        ))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testTerminalRevealURLPreservesFullITermSessionID() {
        let target = TerminalTarget(sessionID: "w0t1p2:ABC DEF")
        XCTAssertEqual(target.uniqueID, "ABC DEF")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(target.revealURL), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "w0t1p2:ABC DEF")
    }

    func testTerminalTargetsExposeTheirApplicationForPillIcons() {
        XCTAssertEqual(TerminalTarget(sessionID: "w0t1:ABC").applicationKind, .iterm)
        XCTAssertEqual(TerminalTarget(sessionID: "terminal:Apple_Terminal:/dev/ttys001").applicationKind, .terminal)
        XCTAssertEqual(TerminalTarget(sessionID: "terminal:ghostty:/dev/ttys002").applicationKind, .ghostty)
        XCTAssertEqual(TerminalTarget(sessionID: "terminal:WarpTerminal:/dev/ttys003").applicationKind, .warp)
        XCTAssertEqual(TerminalTarget(sessionID: "terminal:WezTerm:/dev/ttys004").applicationKind, .wezterm)
        XCTAssertEqual(TerminalTarget(sessionID: "terminal:xterm-kitty:/dev/ttys005").applicationKind, .kitty)
        XCTAssertEqual(TerminalTarget(sessionID: "terminal:Apple_Terminal:/dev/ttys001").tty, "/dev/ttys001")
        XCTAssertEqual(TerminalApplicationKind.terminal.bundleIdentifier, "com.apple.Terminal")
    }

    func testTerminalIdentityCapturesExactAdapterIDsAndRemoteContext() {
        let identity = TerminalIdentity.capture(environment: [
            "__CFBundleIdentifier": "com.github.wez.wezterm",
            "WEZTERM_PANE": "42",
            "WEZTERM_UNIX_SOCKET": "/tmp/wez.sock",
            "TTY": "/dev/ttys042",
            "SSH_TTY": "/dev/pts/4",
            "SSH_CONNECTION": "192.0.2.10 5555 192.0.2.20 22"
        ], sourceProcessID: 900)

        XCTAssertEqual(identity?.application, .wezterm)
        XCTAssertEqual(identity?.weztermPane, "42")
        XCTAssertEqual(identity?.weztermUnixSocket, "/tmp/wez.sock")
        XCTAssertEqual(identity?.sshTTY, "/dev/pts/4")
        XCTAssertEqual(identity?.sshConnection, "192.0.2.10 5555 192.0.2.20 22")
        let target = TerminalTarget(sessionID: identity?.sessionID ?? "")
        XCTAssertEqual(target.applicationKind, .wezterm)
        XCTAssertEqual(target.exactIdentifier, "42")
        XCTAssertEqual(target.remoteSocket, "/tmp/wez.sock")
    }

    func testTerminalIdentityCapturesMultiplexersWithoutGuessingTargets() {
        let tmux = TerminalIdentity.capture(environment: [
            "TERM_PROGRAM": "Ghostty",
            "TMUX": "/tmp/tmux-501/default,12345,0",
            "TMUX_PANE": "%7",
            "TTY": "/dev/ttys007"
        ])
        XCTAssertEqual(tmux?.multiplexer, .tmux)
        XCTAssertEqual(tmux?.tmuxPane, "%7")
        XCTAssertEqual(TerminalTarget(sessionID: tmux?.sessionID ?? "").multiplexer, .tmux)
        XCTAssertEqual(TerminalTarget(sessionID: tmux?.sessionID ?? "").exactIdentifier, "%7")

        let zellij = TerminalIdentity.capture(environment: [
            "TERM_PROGRAM": "iTerm2",
            "ZELLIJ_SESSION_NAME": "work",
            "ZELLIJ_PANE_ID": "2"
        ])
        XCTAssertEqual(zellij?.multiplexer, .zellij)
        XCTAssertEqual(zellij?.zellijSessionName, "work")
        XCTAssertEqual(zellij?.zellijPaneID, "2")
    }

    func testOldTerminalTargetCodablePayloadStillRoundTripsOnlySessionID() throws {
        let old = Data(#"{"sessionID":"w0t1:ABC-123"}"#.utf8)
        let target = try JSONDecoder().decode(TerminalTarget.self, from: old)
        XCTAssertEqual(target.sessionID, "w0t1:ABC-123")
        XCTAssertEqual(try JSONDecoder().decode(TerminalTarget.self, from: JSONEncoder().encode(target)), target)
    }

    func testTerminalAdaptersUseExactIDsAndFixtureGuard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let navigator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermNavigator.swift"))
        let sender = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermPromptSender.swift"))
        let bridge = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeBridge/main.swift"))

        XCTAssertTrue(navigator.contains("WEZTERM_UNIX_SOCKET"))
        XCTAssertTrue(navigator.contains("activate-pane"))
        XCTAssertTrue(navigator.contains("focusGhostty"))
        XCTAssertTrue(navigator.contains("focus terminalSurface"))
        XCTAssertTrue(navigator.contains("select-pane"))
        XCTAssertTrue(navigator.contains("focus-window"))
        XCTAssertTrue(sender.contains("if usesFixture { return .sent }"))
        XCTAssertTrue(sender.contains("send-text"))
        XCTAssertTrue(sender.contains("send-keys"))
        XCTAssertTrue(sender.contains("submitPromptGhostty"))
        XCTAssertTrue(sender.contains("kittyRemoteSocket"))
        XCTAssertTrue(bridge.contains("TerminalIdentity.capture"))
    }

    func testMissingGhosttyNeverOpensAnApplicationChooserAtLaunch() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in ["ITermNavigator.swift", "ITermPromptSender.swift"] {
            let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/\(file)"))
            XCTAssertTrue(source.contains("Self.ghosttyIsInstalled"), file)
            XCTAssertTrue(source.contains("private static var ghosttyIsInstalled: Bool"), file)
            XCTAssertTrue(source.contains("/Applications/Ghostty.app"), file)
        }
    }

    func testNavigatorRoutesGenericTerminalTargetsInsteadOfSendingThemToITerm() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermNavigator.swift"))
        XCTAssertTrue(source.contains("switch target.applicationKind"))
        XCTAssertTrue(source.contains("private func revealTerminal"))
        XCTAssertTrue(source.contains("tty of terminalTab as text"))
        XCTAssertTrue(source.contains("private func activateApplication"))
        XCTAssertTrue(source.contains("process.arguments = [\"-b\", bundleIdentifier]"))
    }

    func testPromptSenderRoutesTerminalAppByTTYAndRejectsUnsupportedAppsClearly() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermPromptSender.swift"))
        XCTAssertTrue(source.contains("if target.applicationKind == .terminal"))
        XCTAssertTrue(source.contains("tty of terminalTab as text"))
        XCTAssertTrue(source.contains("do script (promptText as text) in terminalTab"))
        XCTAssertTrue(source.contains("Sending from Noturcode is not available for"))
        XCTAssertTrue(source.contains("target.applicationKind == .iterm"))
    }

    func testPillActivityCollapseCoordinatesOuterAndInnerGeometry() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))
        let sessions = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))

        XCTAssertTrue(surface.contains("value: surfaceHeight"))
        XCTAssertFalse(sessions.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertTrue(coordinator.contains("return summaryAllowance"))
        XCTAssertFalse(coordinator.contains("activityExpandedSessionID"))
        XCTAssertFalse(coordinator.contains("toggleActivityExpansion"))
        XCTAssertFalse(coordinator.contains("hoveredSessionID == nil ? 0 : 95"))
    }

    func testExpandedNotchMorphsContentInsideOnePersistentHeader() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))

        XCTAssertTrue(surface.contains("private var dockHeader: some View"))
        XCTAssertFalse(surface.contains("private var activeDockHeader: some View"))
        XCTAssertFalse(surface.contains("private var persistentDockHeader: some View"))
        let stackStart = try XCTUnwrap(surface.range(of: "VStack(spacing: 0)"))
        let headerDefinition = try XCTUnwrap(surface.range(of: "private var dockHeader"))
        let composition = String(surface[stackStart.lowerBound..<headerDefinition.lowerBound])
        let header = try XCTUnwrap(composition.range(of: "dockHeader"))
        let details = try XCTUnwrap(composition.range(of: "expandedDetails"))
        XCTAssertLessThan(header.lowerBound, details.lowerBound)
        XCTAssertTrue(composition.contains(".transition(coordinatedContentTransition)"))
        XCTAssertTrue(surface.contains("metrics.expandedSurfaceHeight("))
        XCTAssertFalse(surface.contains(".padding(.top, metrics.neckHeight + 9)"))

        let adaptiveStart = try XCTUnwrap(surface.range(of: "private struct AdaptiveDockHeader"))
        let announcementStart = try XCTUnwrap(surface.range(of: "struct AnnouncementView"))
        let adaptive = String(surface[adaptiveStart.lowerBound..<announcementStart.lowerBound])
        XCTAssertTrue(adaptive.contains("NoturcodeBrandMark(size: 19)"))
        XCTAssertTrue(adaptive.contains("ZStack(alignment: .leading)"))
        XCTAssertTrue(adaptive.contains("sessionStrip(sessions)"))
        XCTAssertTrue(adaptive.contains(".opacity(isExpanded ? 0 : 1)"))
        XCTAssertTrue(adaptive.contains("BillGatesQuoteRotator("))
        XCTAssertTrue(adaptive.contains(".opacity(isExpanded ? 1 : 0)"))
        XCTAssertTrue(adaptive.contains("private var compactContentAnimation: Animation?"))
        XCTAssertTrue(adaptive.contains("private var quoteContentAnimation: Animation?"))
        XCTAssertTrue(adaptive.contains(".delay(0.06)"))
        XCTAssertTrue(adaptive.contains(".animation(compactContentAnimation, value: isExpanded)"))
        XCTAssertTrue(adaptive.contains(".animation(quoteContentAnimation, value: isExpanded)"))
        XCTAssertFalse(adaptive.contains(".scaleEffect(x:"))
        XCTAssertFalse(adaptive.contains(".animation(.easeOut(duration: 0.14), value: isExpanded)"))
    }

    func testExpandedNotchSessionRowsDoNotRenderToolActivityInspector() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessions = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertFalse(sessions.contains("private struct SessionActivityInspector"))
        XCTAssertFalse(sessions.contains("activity-expand-"))
        XCTAssertFalse(sessions.contains("activity-scroll-"))
        XCTAssertFalse(sessions.contains("if isHovered || isActivityExpanded"))
    }

    func testExpandedNotchSessionRowKeepsFullNameAndHidesTokenCounter() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let rowStart = try XCTUnwrap(source.range(of: "private struct SessionRow"))
        let nextStart = try XCTUnwrap(source.range(of: "private struct ConversationSidebarToggle"))
        let row = String(source[rowStart.lowerBound..<nextStart.lowerBound])

        XCTAssertTrue(row.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(row.contains("if session.key.source != .codex"))
        XCTAssertTrue(row.contains(".clickableCursor()"))
        XCTAssertFalse(row.contains("if let tokens = session.tokens"))
        XCTAssertFalse(row.contains("DurationFormatting.tokens"))
    }

    func testAnnouncementUsesNativePointingHandCursor() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let hostingStart = try XCTUnwrap(source.range(of: "private final class AnnouncementHostingView"))
        let hosting = String(source[hostingStart.lowerBound...])

        XCTAssertTrue(hosting.contains("override func resetCursorRects()"))
        XCTAssertTrue(hosting.contains("addCursorRect(bounds, cursor: .pointingHand)"))
    }

    func testClickableCursorDefersReassertionUntilAfterAppKitCursorDispatch() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let cursorStart = try XCTUnwrap(source.range(of: "private final class PointingHandCursorCoordinator"))
        let brandStart = try XCTUnwrap(source.range(of: "struct NoturcodeBrandMark"))
        let cursor = String(source[cursorStart.lowerBound..<brandStart.lowerBound])

        XCTAssertTrue(cursor.contains("NSViewRepresentable"))
        XCTAssertTrue(cursor.contains("override func resetCursorRects()"))
        XCTAssertTrue(cursor.contains("addCursorRect(clippedBounds, cursor: .pointingHand)"))
        XCTAssertTrue(cursor.contains("override func hitTest"))
        XCTAssertTrue(cursor.contains("return nil"))
        XCTAssertTrue(cursor.contains("NSTrackingArea"))
        XCTAssertTrue(cursor.contains(".mouseMoved"))
        XCTAssertTrue(cursor.contains("override func mouseMoved"))
        XCTAssertTrue(cursor.contains("NSCursor.pointingHand.push()"))
        XCTAssertTrue(cursor.contains("NSCursor.pop()"))
        XCTAssertTrue(cursor.contains("window.enableCursorRects()"))
        XCTAssertTrue(cursor.contains("window.resetCursorRects()"))
        XCTAssertFalse(cursor.contains("window?.invalidateCursorRects(for: self)"))
        XCTAssertFalse(cursor.contains("NSCursor.arrow.set()"))
        XCTAssertFalse(cursor.contains(".activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate"))
        XCTAssertTrue(cursor.contains("NSEvent.addLocalMonitorForEvents"))
        XCTAssertTrue(cursor.contains("DispatchQueue.main.async"))
        XCTAssertTrue(cursor.contains("applyCursor"))
        XCTAssertTrue(cursor.contains(".onContinuousHover"))
        XCTAssertTrue(cursor.contains("NSCursor.pointingHand.push()"))
        XCTAssertTrue(cursor.contains("NSCursor.pop()"))
    }

    func testNotchRebuildsCursorRectsWhenItBecomesInteractive() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let pointerStart = try XCTUnwrap(source.range(of: "func pointerMoved(inside: Bool)", options: .backwards))
        let dismissStart = try XCTUnwrap(source.range(of: "\n    func dismiss()", range: pointerStart.lowerBound..<source.endIndex))
        let pointer = String(source[pointerStart.lowerBound..<dismissStart.lowerBound])

        XCTAssertTrue(pointer.contains("ignoresMouseEvents"))
        XCTAssertTrue(pointer.contains("panel.enableCursorRects()"))
        XCTAssertTrue(pointer.contains("panel.resetCursorRects()"))
        XCTAssertFalse(pointer.contains("invalidateCursorRects"))

        let interaction = try XCTUnwrap(pointer.range(of: "panel.ignoresMouseEvents = ignoresMouseEvents"))
        let cursor = try XCTUnwrap(pointer.range(of: "updatePanelKeyForCursor(inside: inside)"))
        XCTAssertLessThan(interaction.lowerBound, cursor.lowerBound)
    }

    func testCompactSurfaceStartsAtTheScreenTop() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))

        XCTAssertTrue(source.contains("var surfaceTopInset: CGFloat { 0 }"))
        XCTAssertFalse(source.contains("var surfaceTopInset: CGFloat { hasHardwareNotch ? 0 : 7 }"))
    }

    func testNotchPanelLevelIsAppliedAfterFloatingPanelConfiguration() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let controllerStart = try XCTUnwrap(source.range(of: "final class NotchPanelController"))
        let updateStart = try XCTUnwrap(source.range(of: "\n    func update(screen:", range: controllerStart.lowerBound..<source.endIndex))
        let initializer = String(source[controllerStart.lowerBound..<updateStart.lowerBound])
        let floating = try XCTUnwrap(initializer.range(of: "panel.isFloatingPanel = true"))
        let level = try XCTUnwrap(initializer.range(of: "panel.level = NSWindow.Level"))

        XCTAssertLessThan(floating.lowerBound, level.lowerBound)
    }

    func testNotchPanelAcceptsMouseMovedEventsForClickableCursorRegions() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let controllerStart = try XCTUnwrap(source.range(of: "final class NotchPanelController"))
        let announcementStart = try XCTUnwrap(source.range(of: "private final class AnnouncementHostingView"))
        let controller = String(source[controllerStart.lowerBound..<announcementStart.lowerBound])

        XCTAssertTrue(controller.contains("panel.acceptsMouseMovedEvents = true"))
        XCTAssertTrue(controller.contains("panel.isFloatingPanel = true"))
        XCTAssertTrue(controller.contains("panel.becomesKeyOnlyIfNeeded = true"))
        XCTAssertTrue(controller.contains("panel.allowsToolTipsWhenApplicationIsInactive = true"))
        XCTAssertFalse(source.contains("final class NotchHostingView: NSHostingView<NotchSurfaceView>"))
        XCTAssertFalse(source.contains("addCursorRect(clickableBounds, cursor: .pointingHand)"))
        XCTAssertTrue(controller.contains("panel.enableCursorRects()"))
        XCTAssertTrue(controller.contains("panel.resetCursorRects()"))
        XCTAssertFalse(controller.contains("func updateSurfaceCursor(inside: Bool)"))
        XCTAssertFalse(source.contains("private final class NotchSurfaceCursorCoordinator"))
        XCTAssertTrue(controller.contains("panel.makeKey()"))
        XCTAssertTrue(controller.contains("panel.resignKey()"))
        XCTAssertTrue(controller.contains("surfaceMadeKeyForCursor"))
        XCTAssertFalse(controller.contains("NSApp.activate"))
        XCTAssertFalse(controller.contains("cursorBeforeSurface"))
        XCTAssertFalse(controller.contains("surfaceOwnsCursor"))
        XCTAssertTrue(source.contains("override func constrainFrameRect"))
        XCTAssertTrue(source.contains("return frameRect"))

        let surface = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))
        let headerStart = try XCTUnwrap(surface.range(of: "private struct AdaptiveDockHeader"))
        let cacheStart = try XCTUnwrap(surface.range(of: "@MainActor\nprivate final class TerminalIconCache"))
        let header = String(surface[headerStart.lowerBound..<cacheStart.lowerBound])
        XCTAssertEqual(header.components(separatedBy: ".clickableCursor()").count - 1, 1)
    }

    func testExpandedSessionHoverFeedbackHasNoIntentDelay() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let start = try XCTUnwrap(source.range(of: "func setHoveredSession(_ id: String?)"))
        let end = try XCTUnwrap(source.range(of: "\n    func expand()", range: start.lowerBound..<source.endIndex))
        let method = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(method.contains("hoveredSessionID = id"))
        XCTAssertFalse(method.contains("milliseconds(90)"))
        XCTAssertFalse(method.contains("hoverIntentTask"))
    }

    func testTerminalDiscoveryDoesNotClaimUnverifiedAdaptersAreConfigured() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/IntegrationBootstrapper.swift"))

        XCTAssertTrue(source.contains("configured: detected && id == \"iterm\""))
        XCTAssertFalse(source.contains("detected: fileManager.fileExists(atPath: path), configured: true"))
    }

    func testDesktopNewSessionMenuWiresAllNativeProviders() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))
        let status = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/StatusWindowController.swift"))
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NativeSessionCoordinator.swift"))

        XCTAssertTrue(appModel.contains("func createNativeSession(provider: NativeAgentProvider)"))
        XCTAssertTrue(appModel.contains("connectOpenCodeServer()"))
        XCTAssertTrue(status.contains("Menu"))
        XCTAssertTrue(status.contains("Start Codex"))
        XCTAssertTrue(status.contains("Start Gemini"))
        XCTAssertTrue(status.contains("Start Grok"))
        XCTAssertTrue(status.contains("Connect OpenCode"))
        XCTAssertTrue(status.contains("createNativeSession(provider: .codex)"))
        XCTAssertTrue(status.contains("createNativeSession(provider: .gemini)"))
        XCTAssertTrue(status.contains("createNativeSession(provider: .grok)"))
        XCTAssertTrue(coordinator.contains("func startOpenCode"))
        XCTAssertTrue(coordinator.contains("transport == .openCodeServer"))
    }

    func testJSONRPCLineDecoderHandlesFragmentsAndReportsMalformedLines() throws {
        var decoder = JSONRPCLineDecoder()
        XCTAssertTrue(decoder.append(Data(#"{"jsonrpc":"2.0","method":"turn/"#.utf8)).isEmpty)
        let events = decoder.append(Data("started\",\"params\":{\"threadId\":\"t1\"}}\nnot-json\n".utf8))
        XCTAssertEqual(events.count, 2)
        guard case let .message(message) = events[0] else { return XCTFail("Expected a decoded message") }
        XCTAssertEqual(message.method, "turn/started")
        XCTAssertEqual(message.params?.firstString(for: ["threadId"]), "t1")
        guard case let .malformed(line) = events[1] else { return XCTFail("Expected a malformed line") }
        XCTAssertEqual(line, "not-json")
    }

    func testLineJSONRPCProcessRoundTripsARequest() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("System Python is unavailable")
        }
        let fixture = """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            response = {"jsonrpc":"2.0", "id":request["id"], "result":request.get("params", {})}
            print(json.dumps(response), flush=True)
        """
        let transport = LineJSONRPCProcess(configuration: .init(
            executableURL: python,
            arguments: ["-u", "-c", fixture]
        ))
        try await transport.start { _ in }
        let result = try await transport.request(
            method: "fixture/ping",
            params: .object(["value": .string("pong")]),
            timeout: .seconds(2)
        )
        XCTAssertEqual(result.firstString(for: ["value"]), "pong")
        await transport.stop()
    }

    func testCodexAppServerEventMapperPreservesThreadTurnAndDeltaIDs() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-2","itemId":"item-3","delta":"hello"}}"#.utf8)
        let message = try JSONDecoder().decode(LineJSONRPCMessage.self, from: data)
        XCTAssertEqual(
            CodexAppServerEventMapper.map(message),
            .agentMessageDelta(
                threadID: "thread-1",
                turnID: "turn-2",
                itemID: "item-3",
                delta: "hello"
            )
        )

        let approval = LineJSONRPCMessage(
            id: .number(9),
            method: "item/permissions/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "reason": .string("Needs network access")
            ])
        )
        XCTAssertEqual(
            CodexAppServerEventMapper.map(approval),
            .askingYou(
                threadID: "thread-1",
                requestID: .number(9),
                method: "item/permissions/requestApproval",
                params: .object([
                    "threadId": .string("thread-1"),
                    "reason": .string("Needs network access")
                ])
            )
        )
    }

    func testNativeApprovalRequestsHaveVisibleExplicitResponseControls() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NativeSessionCoordinator.swift"))
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(coordinator.contains("func respond(to approval: PendingApproval"))
        XCTAssertTrue(coordinator.contains("respondToServerRequest"))
        XCTAssertTrue(coordinator.contains("respondToPermission"))
        XCTAssertTrue(coordinator.contains("OpenCodePermissionReply"))
        XCTAssertTrue(coordinator.contains("pendingApprovals.removeValue"))
        XCTAssertTrue(views.contains("private struct NativeApprovalCard"))
        XCTAssertTrue(views.contains("native-approval-card"))
        XCTAssertTrue(views.contains("native-approval-approve-once"))
        XCTAssertTrue(views.contains("native-approval-reject"))
    }

    func testNativeCoordinatorRestoresCapabilityBackedACPSessions() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NativeSessionCoordinator.swift"))

        XCTAssertTrue(coordinator.contains("nativeSession?.transport == .acp"))
        XCTAssertTrue(coordinator.contains("restoreACPSession"))
        XCTAssertTrue(coordinator.contains("supportsLoadSession"))
        XCTAssertTrue(coordinator.contains("loadSession(sessionID:"))
        XCTAssertTrue(coordinator.contains("acpTokensBySession[session.key] = clientToken"))
    }

    func testExpandedNotchShowsRotatingQuoteAndKeepsEverySessionInList() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))

        XCTAssertTrue(surface.contains("private struct BillGatesQuoteRotator"))
        XCTAssertTrue(surface.contains("BillGatesQuoteRotator("))
        XCTAssertTrue(surface.contains("sessions: store.sortedSessions"))
        XCTAssertTrue(surface.contains("The world can get better."))
        XCTAssertTrue(surface.contains("The acceleration of innovation is just starting."))
        XCTAssertTrue(surface.contains("Task.sleep(for: .seconds(10))"))
        XCTAssertTrue(surface.contains("contentTransition(.opacity)"))
        XCTAssertTrue(surface.contains("accessibilityIdentifier(\"bill-gates-quote\")"))
        XCTAssertFalse(surface.contains("remainingSessions"))
        XCTAssertFalse(surface.contains("latestPromptSession"))
        XCTAssertFalse(surface.contains("headerLabel"))
        XCTAssertFalse(surface.contains("Text(preview)"))
        XCTAssertFalse(surface.contains("Text(\"View chat\")"))
        XCTAssertFalse(surface.contains("activeSubagents"))
        XCTAssertFalse(surface.contains("session.currentActivity"))
    }

    func testCompactPillShowsBrandAndEverySessionNameWithoutToolActivity() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))

        XCTAssertTrue(surface.contains("NoturcodeBrandMark(size:"))
        XCTAssertTrue(surface.contains("private func sessionChip(_ session: TrackedSession, width: CGFloat)"))
        XCTAssertTrue(surface.contains("ForEach(visibleSessions)"))
        XCTAssertTrue(surface.contains("Text(session.name)"))
        XCTAssertTrue(surface.contains(".lineLimit(1)"))
        XCTAssertTrue(surface.contains(".frame(height: metrics.dockRailHeight(sessionCount: sessions.count))"))
        XCTAssertTrue(surface.contains(".frame(maxHeight: .infinity, alignment: .top)"))
        XCTAssertFalse(surface.contains(".scrollClipDisabled()"))
        XCTAssertFalse(surface.contains("compactActivityText"))
        XCTAssertFalse(surface.contains("session.currentActivity"))
        XCTAssertTrue(surface.contains("metrics.collapsedWidth(sessionNames: store.sessions.map(\\.name))"))
        XCTAssertTrue(surface.contains("let chipWidth = values.map { metrics.sessionChipWidth(for: $0.name) }.max()"))
        XCTAssertTrue(coordinator.contains("func collapsedWidth(sessionNames: [String])"))
        XCTAssertTrue(coordinator.contains("sessionNames.map(sessionChipWidth(for:)).max()"))
        XCTAssertTrue(coordinator.contains("CGFloat(compactItemCount(sessionCount: sessionNames.count)) * widestChip"))
        XCTAssertFalse(coordinator.contains("sessionNames.map(sessionChipWidth(for:)).reduce(0, +)"))
        XCTAssertFalse(coordinator.contains("CGFloat(sessionCount) * 88"))
        XCTAssertTrue(surface.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertTrue(surface.contains("HStack(spacing: 6)"))
        XCTAssertFalse(surface.contains("ScrollView(.vertical, showsIndicators: false)"))
        XCTAssertTrue(surface.contains("Array(values.prefix(3))"))
        XCTAssertTrue(surface.contains("let hiddenSessions = Array(values.dropFirst(3))"))
        XCTAssertTrue(surface.contains("let overflowCount = max(0, values.count - 3)"))
        XCTAssertTrue(surface.contains("overflowChip(sessions: hiddenSessions, width: chipWidth)"))
        XCTAssertTrue(surface.contains("private func overflowState(for sessions: [TrackedSession]) -> SessionState"))
        XCTAssertTrue(surface.contains("SessionMarble(") && surface.contains("name: \"More sessions\""))
        XCTAssertTrue(surface.contains("size: 20"))
        XCTAssertTrue(surface.contains("animate: true"))
        XCTAssertTrue(surface.contains("Text(overflowState.displayName.lowercased())"))
        XCTAssertTrue(surface.contains(".frame(width: width, height: 30, alignment: .leading)"))
        XCTAssertTrue(surface.contains("onShowAll: { state.expand() }"))
        XCTAssertTrue(coordinator.contains("func expand()"))

        let chipStart = try XCTUnwrap(surface.range(of: "private func sessionChip"))
        let announcementStart = try XCTUnwrap(surface.range(of: "struct AnnouncementView"))
        let chip = String(surface[chipStart.lowerBound..<announcementStart.lowerBound])
        let padding = try XCTUnwrap(chip.range(of: ".padding(.horizontal, 7)"))
        let measuredFrame = try XCTUnwrap(chip.range(of: ".frame(width: width, height: 30"))
        XCTAssertLessThan(padding.lowerBound, measuredFrame.lowerBound)
        XCTAssertFalse(coordinator.contains("max(340"))
    }

    func testDoneSummaryPopoverShowsOnlyAgentWrittenStatus() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessions = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))

        XCTAssertTrue(sessions.contains("lineLimit(2, reservesSpace: true)"))
        XCTAssertTrue(sessions.contains(".popover(isPresented: $isPresented, arrowEdge: .trailing)"))
        XCTAssertTrue(sessions.contains("accessibilityIdentifier(\"done-summary-popover-"))
        XCTAssertFalse(sessions.contains("private var responseActivities"))
        XCTAssertFalse(sessions.contains("done-summary-steps-"))
        XCTAssertFalse(sessions.contains("Steps in this response"))
        XCTAssertTrue(sessions.contains("guard session.state.showsCompletionSummary else { return nil }"))
        XCTAssertTrue(sessions.contains("if session.state == .working"))
        XCTAssertTrue(sessions.contains("return \"Working on the current prompt\""))
        XCTAssertTrue(coordinator.contains("CGFloat(summaryCount) * 14"))
        XCTAssertTrue(coordinator.contains("$0.state.showsCompletionSummary"))
    }

    func testDesktopAppUsesConversationFirstShellInsteadOfEmbeddingFloatingCardChrome() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let status = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/StatusWindowController.swift"))
        let sessions = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(status.contains("sessionSection(\"Needs attention\""))
        XCTAssertTrue(status.contains("sessionSection(\"Working\""))
        XCTAssertTrue(status.contains("sessionSection(\"Recent\""))
        XCTAssertTrue(status.contains("accessibilityIdentifier(\"desktop-session-sidebar\")"))
        XCTAssertTrue(status.contains("identifier: \"toggle-desktop-session-sidebar\""))
        XCTAssertTrue(status.contains("noturcode.full-app-shell-v2-sized"))
        XCTAssertTrue(status.contains("max(1_240, visible.width * 0.88)"))
        XCTAssertFalse(status.contains("navigationRail"))
        XCTAssertFalse(status.contains("Resume chat"))
        XCTAssertTrue(sessions.contains("presentation == .floating"))
        XCTAssertTrue(sessions.contains("CommandLine.arguments.contains(\"--ui-test-agent-conversation\")"))
        XCTAssertTrue(sessions.contains("presentation == .desktop ? 880 : .infinity"))
        XCTAssertTrue(sessions.contains("accessibilityIdentifier(\"toggle-desktop-workflow\")"))
        XCTAssertTrue(sessions.contains("guard session.state.showsCompletionSummary"))
        XCTAssertTrue(sessions.contains("else if presentation == .floating"))
        XCTAssertTrue(sessions.contains("private var shouldShowSummaryCard: Bool"))
    }

    func testExactITermNavigationScriptCompilesAndVerifiesUUID() throws {
        let source = ITermNavigationScript.source
        XCTAssertTrue(source.contains("set wantedID to targetID as text"))
        XCTAssertTrue(source.contains("set wantedTTY to targetTTY as text"))
        XCTAssertTrue(source.contains("tty of terminalSession as text"))
        XCTAssertTrue(source.contains("if wantedTTY is not \"\""))
        XCTAssertTrue(source.contains("set targetWindowID to id of terminalWindow"))
        XCTAssertTrue(source.contains("first window whose id is targetWindowID"))
        XCTAssertTrue(source.contains("select targetWindow"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "first window whose id is targetWindowID").count - 1,
            2
        )
        XCTAssertFalse(source.contains("set targetWindow to current window"))
        XCTAssertTrue(source.contains("is wantedID"))
        XCTAssertFalse(source.contains("is targetID"))
        XCTAssertFalse(source.contains("contents of"))
        XCTAssertTrue(source.contains("repeat with terminalSession in sessions of terminalTab"))
        XCTAssertTrue(source.contains("unique ID of current session of terminalTab"))
        try requireITermScriptingDictionary()
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testPaneHighlightIsPassiveAndBoundedToResolvedTerminalGeometry() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let overlay = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/TerminalPaneHighlightCoordinator.swift"))
        let resolver = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermPaneGeometryResolver.swift"))
        let model = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))

        XCTAssertTrue(resolver.contains("kAXFocusedUIElementAttribute"))
        XCTAssertTrue(resolver.contains("kAXTextAreaRole"))
        XCTAssertTrue(resolver.contains("kAXPositionAttribute"))
        XCTAssertTrue(resolver.contains("kAXSizeAttribute"))
        XCTAssertFalse(resolver.contains("AXIsProcessTrustedWithOptions"))
        XCTAssertFalse(resolver.contains("AXTrustedCheckOptionPrompt"))
        XCTAssertTrue(resolver.contains("tell application \"System Events\""))
        XCTAssertTrue(resolver.contains("set px to (item 1 of panePosition) as integer"))
        XCTAssertFalse(resolver.contains("return systemEventsFocusedPaneFrame()"))
        XCTAssertTrue(resolver.contains("decodedFrame(topLeft: topLeft, size: size)"))
        XCTAssertTrue(resolver.contains("best.visibleRatio >= 0.80"))
        XCTAssertTrue(resolver.contains("[value, value / 10, value / 100, value / 1_000]"))
        XCTAssertTrue(overlay.contains("styleMask: [.borderless, .nonactivatingPanel]"))
        XCTAssertTrue(overlay.contains("ignoresMouseEvents = true"))
        XCTAssertTrue(overlay.contains("collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]"))
        XCTAssertTrue(overlay.contains("try await Task.sleep(for: .milliseconds(1800))"))
        XCTAssertTrue(overlay.contains("private let highlightColor = Color(red: 0.20, green: 0.88, blue: 1.00)"))
        XCTAssertTrue(overlay.contains("PaneCornerBrackets"))
        XCTAssertTrue(overlay.contains("SpotlightBackdropView"))
        XCTAssertTrue(overlay.contains("private final class SpotlightBackdropView: NSView"))
        XCTAssertFalse(overlay.contains("NSVisualEffectView"))
        XCTAssertTrue(overlay.contains("maskLayer.fillRule = .evenOdd"))
        XCTAssertTrue(overlay.contains("backdropPanels"))
        XCTAssertTrue(overlay.contains("panel.ignoresMouseEvents = true"))
        XCTAssertTrue(overlay.contains("NSAnimationContext.runAnimationGroup"))
        XCTAssertTrue(overlay.contains("Text(\"Focused pane\")"))
        XCTAssertFalse(overlay.contains("Color.accentColor"))
        XCTAssertFalse(overlay.contains(".fill(Color"))
        XCTAssertTrue(model.contains("paneHighlight.show(frame: frame, session: session)"))
        XCTAssertTrue(model.contains("showPaneSpotlight(for: session)"))
        let jumpBody = try XCTUnwrap(model.range(of: "func jump(to session:"))
        let jumpRemainder = model[jumpBody.lowerBound...]
        let jumpEnd = try XCTUnwrap(jumpRemainder.range(of: "func showStatusWindow()"))
        XCTAssertFalse(jumpRemainder[..<jumpEnd.lowerBound].contains("displayCoordinator?.dismissAll()"))
        XCTAssertFalse(views.contains(#".accessibilityIdentifier("open-cli-\(session.id)")"#))
        XCTAssertFalse(views.contains("Text(\"Open CLI\")"))
        XCTAssertTrue(views.contains(".onTapGesture(perform: onSelect)"))
        XCTAssertTrue(model.contains("try await Task.sleep(for: .milliseconds(55))"))
        XCTAssertFalse(model.contains("for attempt in 0..<8"))
        XCTAssertFalse(model.contains("try await Task.sleep(for: .milliseconds(60))"))
        XCTAssertTrue(model.contains("logNavigation(\"revealed\", session: session)"))
        XCTAssertTrue(model.contains("Could not focus"))
        XCTAssertTrue(model.contains("The session is still connected"))
        XCTAssertFalse(model.contains("store.remove(session.key, staleMessage:"))
        XCTAssertFalse(model.contains("requestAccessIfNeeded()"))
    }

    func testEncodedITermSessionTargetUsesUUIDAndKeepsTTYFallback() throws {
        let uuid = "23FB1192-1E94-4C6D-AFD8-958D891E2C3B"
        let target = TerminalTarget(
            sessionID: "terminal:iterm:session:w0t0p3%3A\(uuid)?tty=%2Fdev%2Fttys011"
        )

        XCTAssertEqual(target.identity?.nativeSessionID, "w0t0p3:\(uuid)")
        XCTAssertEqual(target.uniqueID, uuid)
        XCTAssertEqual(target.tty, "/dev/ttys011")
    }

    func testBridgeTerminalIdentityAddsControllingTTYForRemoteNavigationFallback() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeBridge/main.swift"))

        XCTAssertTrue(bridge.contains("ProcessAncestry.terminalTTY(pid: parentPID)"))
        XCTAssertTrue(bridge.contains("environment[\"TTY\"] = tty"))
    }

    func testITermTTYLookupIsReadOnlyAndCompiles() throws {
        let source = ITermSessionLookupScript.source
        XCTAssertTrue(source.contains("tty of terminalSession as text"))
        XCTAssertTrue(source.contains("unique ID of terminalSession as text"))
        XCTAssertFalse(source.contains("activate"))
        XCTAssertFalse(source.contains("select terminal"))
        XCTAssertFalse(source.contains("write text"))
        try requireITermScriptingDictionary()
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }

    @MainActor
    func testSessionStorePersistsTerminalRebinding() throws {
        let privateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-rebind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let fileURL = privateDirectory.appendingPathComponent("connected-sessions.json")
        defer { try? FileManager.default.removeItem(at: privateDirectory) }
        let persistence = SessionPersistence(fileURL: fileURL)
        let store = SessionStore(persistence: persistence)
        let key = SessionKey(source: .codex, sessionID: "rebound")
        _ = store.apply(BridgeEvent(
            kind: .connect,
            source: key.source,
            sessionID: key.sessionID,
            name: "test",
            terminalSessionID: "OLD",
            sourceProcessID: 123
        ))

        store.rebindTerminal(for: key, to: TerminalTarget(sessionID: "LIVE"))

        XCTAssertEqual(store.sessions.first?.terminal?.sessionID, "LIVE")
        store.flushPersistenceForTesting()
        XCTAssertEqual(SessionPersistence(fileURL: fileURL).load().first?.terminal?.sessionID, "LIVE")
    }

    func testITermViewportScriptIsReadOnlyAndCompiles() throws {
        let source = ITermViewportScript.source
        XCTAssertTrue(source.contains("text of terminalSession as text"))
        XCTAssertTrue(source.contains("unique ID of terminalSession as text"))
        XCTAssertFalse(source.contains("activate"))
        XCTAssertFalse(source.contains("select terminal"))
        XCTAssertFalse(source.contains("write text"))
        XCTAssertFalse(source.contains("set "))
        try requireITermScriptingDictionary()
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testITermPromptScriptTargetsExactSessionWithoutFocusingITerm() throws {
        let source = ITermPromptScript.source
        XCTAssertTrue(source.contains("tell terminalSession"))
        XCTAssertTrue(source.contains("set wantedID to targetID as text"))
        XCTAssertTrue(source.contains("set outgoingText to promptText as text"))
        XCTAssertTrue(source.contains("write text outgoingText newline false"))
        XCTAssertTrue(source.contains("write text (ASCII character 13) newline false"))
        XCTAssertLessThan(
            try XCTUnwrap(source.range(of: "write text outgoingText newline false")?.lowerBound),
            try XCTUnwrap(source.range(of: "write text (ASCII character 13) newline false")?.lowerBound)
        )
        XCTAssertFalse(source.contains("write text promptText in terminalSession"))
        XCTAssertTrue(source.contains("unique ID of terminalSession as text"))
        XCTAssertFalse(source.contains("activate"))
        XCTAssertFalse(source.contains("select terminal"))
        try requireITermScriptingDictionary()
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testTerminalAppleEventsNeverBlockTheMainActorAndPromptIsOptimistic() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let navigator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermNavigator.swift"))
        let sender = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/ITermPromptSender.swift"))
        let model = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AppModel.swift"))
        let views = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let display = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))
        let store = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeCore/SessionStore.swift"))
        let reader = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/AgentTranscriptReader.swift"))

        XCTAssertTrue(navigator.contains("actor ITermNavigator"))
        XCTAssertFalse(navigator.contains("@MainActor\nfinal class ITermNavigator"))
        XCTAssertTrue(sender.contains("actor ITermPromptSender"))
        XCTAssertFalse(sender.contains("@MainActor\nfinal class ITermPromptSender"))
        XCTAssertTrue(model.contains("await navigator.reveal(target)"))
        XCTAssertTrue(model.contains("if target.applicationKind == .iterm"))
        XCTAssertTrue(views.contains("await sender.send(payload"))
        XCTAssertTrue(views.contains("optimisticEntries.append"))
        XCTAssertTrue(views.contains("entries != transcriptEntries"))
        XCTAssertTrue(views.contains("entries != selectedAgentConversationEntries"))
        XCTAssertTrue(views.contains("optimisticEntries.removeAll"))
        XCTAssertTrue(views.contains("case sending"))
        XCTAssertTrue(views.contains("private struct IsolatedPromptComposer: View"))
        XCTAssertTrue(views.contains("IsolatedPromptComposer("))
        XCTAssertTrue(display.contains("MouseLocationCoalescer"))
        let refreshStart = try XCTUnwrap(display.range(of: "func refresh()"))
        let refreshTail = display[refreshStart.lowerBound...]
        let refreshEnd = try XCTUnwrap(refreshTail.range(of: "func contains("))
        XCTAssertFalse(refreshTail[..<refreshEnd.lowerBound].contains("hostingView.rootView ="))
        XCTAssertTrue(store.contains("class SessionPersistenceDebouncer: @unchecked Sendable"))
        XCTAssertTrue(store.contains("queue.asyncAfter(deadline: .now() + .milliseconds(180)"))
        XCTAssertTrue(store.contains("case .activityStarted, .activityFinished, .subagentStarted, .subagentActivity,"))
        XCTAssertTrue(store.contains(".subagentCompleted, .subagentFailed"))
        XCTAssertTrue(reader.contains("private var nextDiscoveryAt: [SessionKey: Date]"))
        XCTAssertTrue(reader.contains("now.addingTimeInterval(3)"))
        XCTAssertFalse(display.contains("Task.sleep(for: .milliseconds(230))"))
        XCTAssertLessThan(
            try XCTUnwrap(display.range(of: "action()")?.lowerBound),
            try XCTUnwrap(display.range(of: "Task.sleep(for: .milliseconds(80))")?.lowerBound)
        )
    }

    func testITermPromptHandlerExecutesWithoutCoercingITermApplication() throws {
        try requireITermScriptingDictionary()
        let script = try XCTUnwrap(NSAppleScript(source: ITermPromptScript.source))
        var compileError: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&compileError), "\(String(describing: compileError))")

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "submitPrompt"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: "__NOTURCODE_NONEXISTENT_SESSION__"), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: "__NO_SEND__"), at: 2)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var runtimeError: NSDictionary?
        let result = script.executeAppleEvent(event, error: &runtimeError)
        if let number = runtimeError?[NSAppleScript.errorNumber] as? Int, number == -1743 {
            throw XCTSkip("The test bundle has no Apple Events permission; the signed app self-test covers runtime execution.")
        }
        XCTAssertNil(runtimeError, "\(String(describing: runtimeError))")
        XCTAssertEqual(result.stringValue, "MISSING")
    }

    private func requireITermScriptingDictionary() throws {
        guard FileManager.default.fileExists(atPath: "/Applications/iTerm.app") else {
            throw XCTSkip("iTerm2 is not installed; source-shape assertions still cover the generated script on CI.")
        }
    }

    func testNotificationRoutePreservesExactSessionKey() {
        let expected = SessionKey(source: .claude, sessionID: "session:with spaces/and-symbols")
        let metadata = NotificationRoute.metadata(for: expected)
        XCTAssertEqual(
            NotificationRoute.sessionKey(
                source: metadata[NotificationRoute.sourceKey],
                sessionID: metadata[NotificationRoute.sessionIDKey]
            ),
            expected
        )
        XCTAssertNil(NotificationRoute.sessionKey(source: "unknown", sessionID: expected.sessionID))
        XCTAssertNil(NotificationRoute.sessionKey(source: "claude", sessionID: ""))
    }
}
