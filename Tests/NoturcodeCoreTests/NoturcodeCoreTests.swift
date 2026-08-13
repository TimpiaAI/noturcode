import AppKit
import Carbon
import Foundation
import XCTest
@testable import NoturcodeCore

final class NoturcodeCoreTests: XCTestCase {
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
            (".claude/skills/nc/SKILL.md", "name: nc\nNoturcode macOS notch tracker"),
            (".claude/skills/noturcode-summary/SKILL.md", "name: noturcode-summary\n# Noturcode summary"),
            (".codex/skills/noturcode-summary/SKILL.md", "name: noturcode-summary\n# Noturcode summary"),
            ("Library/Application Support/iTerm2/Scripts/AutoLaunch/Ask Noturcode.py", "ro.noturcode.ask-selection\nnoturcode-bridge")
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

    func testDurationAndTokenFormatting() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(DurationFormatting.compact(from: start, to: start.addingTimeInterval(4_088)), "1h 8m")
        XCTAssertEqual(DurationFormatting.relative(from: start, to: start.addingTimeInterval(3)), "just now")
        XCTAssertEqual(DurationFormatting.tokens(286_000), "286k tok")
        XCTAssertEqual(DurationFormatting.tokens(1_250_000), "1.2M tok")
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
        XCTAssertTrue(views.contains("if !entries.isEmpty || transcriptEntries.isEmpty"))
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

    func testSessionDockReflectsPersistentUnreadCompletionState() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notch = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))

        XCTAssertTrue(notch.contains("completionReads: model.completionReads"))
        XCTAssertTrue(notch.contains("completionReads.isUnread(session)"))
        XCTAssertTrue(notch.contains("isUnread: completionReads.isUnread(session)"))
        XCTAssertTrue(notch.contains("completionIsUnread: isUnread"))
        XCTAssertFalse(notch.contains("CollapsedCompletionOutline"))
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

        XCTAssertTrue(coordinator.contains("CGSize(width: 392, height: 96)"))
        XCTAssertTrue(notch.contains(".padding(.vertical, 12)"))
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

    func testSessionDockPlacesOneContinuousRailBelowHardwareNotch() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notch = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))

        XCTAssertTrue(notch.contains(".padding(.top, metrics.hasHardwareNotch ? metrics.neckHeight : 0)"))
        XCTAssertTrue(notch.contains("ForEach(visibleSessions)"))
        XCTAssertFalse(notch.contains("marbleGroup(working)"))
        XCTAssertFalse(notch.contains("marbleGroup(attention)"))
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
        XCTAssertTrue(views.contains("geometry.size.height - 20"))
        XCTAssertTrue(views.contains("private struct PromptTimelineMarker: View"))
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

    func testSessionDockKeepsStableGeometryAndRoutesPrimaryActions() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"))
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))

        XCTAssertTrue(surface.contains("struct SessionDock"))
        XCTAssertTrue(surface.contains("accessibilityIdentifier(\"session-dock\")"))
        XCTAssertTrue(surface.contains("onOpenWorkspace: model.showStatusWindow"))
        XCTAssertTrue(surface.contains("state.select(session) { model.jump(to: session) }"))
        XCTAssertTrue(surface.contains(".scaleEffect(isHovered ? 1.12 : 1)"))
        XCTAssertTrue(surface.contains(".offset(y: isHovered ? -2 : 0)"))
        XCTAssertFalse(surface.contains("ExpandedSessionList("))
        XCTAssertFalse(surface.contains("state.isExpanded"))
        XCTAssertTrue(coordinator.contains("height = metrics.dockHeight"))
        XCTAssertTrue(coordinator.contains("var surfaceTopInset: CGFloat { 0 }"))
        XCTAssertFalse(coordinator.contains("try await Task.sleep(for: .milliseconds(230))"))
    }

    func testDoneSummaryGetsTwoLinesAndResponseScopedHoverPopover() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessions = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"))
        let coordinator = try String(contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/DisplayCoordinator.swift"))

        XCTAssertTrue(sessions.contains("lineLimit(2, reservesSpace: true)"))
        XCTAssertTrue(sessions.contains("activity.startedAt >= session.lastPromptAt"))
        XCTAssertTrue(sessions.contains(".popover(isPresented: $isPresented, arrowEdge: .trailing)"))
        XCTAssertTrue(sessions.contains("accessibilityIdentifier(\"done-summary-popover-"))
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
        XCTAssertTrue(status.contains("accessibilityIdentifier(\"toggle-desktop-session-sidebar\")"))
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
        XCTAssertTrue(resolver.contains("return systemEventsFocusedPaneFrame()"))
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
        XCTAssertTrue(model.contains("try await Task.sleep(for: .milliseconds(90))"))
        XCTAssertTrue(model.contains("for attempt in 0..<8"))
        XCTAssertTrue(model.contains("try await Task.sleep(for: .milliseconds(60))"))
        XCTAssertTrue(model.contains("logNavigation(\"revealed\", session: session)"))
        XCTAssertFalse(model.contains("requestAccessIfNeeded()"))
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

        XCTAssertEqual(store.sessions.first?.terminal.sessionID, "LIVE")
        XCTAssertEqual(SessionPersistence(fileURL: fileURL).load().first?.terminal.sessionID, "LIVE")
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
