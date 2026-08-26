import Foundation
import XCTest
@testable import NoturcodeCore

final class HarnessSupportTests: XCTestCase {
    @MainActor
    func testPiAndOMPStayHarnessesWhenTheyUseACodexModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-harness-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(
            persistence: SessionPersistence(fileURL: directory.appendingPathComponent("sessions.json"))
        )

        for source in [AgentSource.pi, .omp] {
            _ = store.apply(BridgeEvent(
                kind: .connect,
                source: source,
                sessionID: "\(source.rawValue)-session",
                name: "Agent work",
                terminalSessionID: "terminal:iterm:session:\(source.rawValue)",
                provider: "openai-codex",
                model: "gpt-5.6-sol",
                theme: "dark",
                agentRole: source == .omp ? "default" : nil
            ))
        }

        XCTAssertEqual(AgentSource.pi.displayName, "Pi")
        XCTAssertEqual(AgentSource.omp.displayName, "OMP")
        XCTAssertEqual(Set(store.sessions.map(\.key.source)), [.pi, .omp])
        XCTAssertEqual(Set(store.sessions.compactMap(\.model)), ["gpt-5.6-sol"])
        XCTAssertEqual(Set(store.sessions.compactMap(\.provider)), ["openai-codex"])
        XCTAssertEqual(Set(store.sessions.compactMap(\.theme)), ["dark"])

        _ = store.apply(BridgeEvent(
            kind: .promptSubmitted,
            source: .omp,
            sessionID: "omp-session",
            provider: "anthropic",
            model: "claude-opus-4-7",
            theme: "light",
            agentRole: "slow"
        ))
        let omp = try XCTUnwrap(store.sessions.first(where: { $0.key.source == .omp }))
        XCTAssertEqual(omp.key.source, .omp)
        XCTAssertEqual(omp.provider, "anthropic")
        XCTAssertEqual(omp.model, "claude-opus-4-7")
        XCTAssertEqual(omp.theme, "light")
        XCTAssertEqual(omp.agentRole, "slow")
    }

    func testHermesKeepsHarnessIdentityAndParsesStateDatabaseRows() throws {
        XCTAssertEqual(AgentSource.hermes.displayName, "Hermes Agent")
        XCTAssertTrue(ProcessAncestry.isAgentProcess(
            "/Users/test/.hermes/hermes-agent/venv/bin/python"
        ))

        let rows = #"[{"message_id":1,"role":"user","content":"Inspect it","timestamp":1787734800.0,"model":"gpt-5.6-sol","provider":"openai-codex"},{"message_id":2,"role":"assistant","content":"","tool_calls":"[{\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]","timestamp":1787734801.0,"model":"gpt-5.6-sol","provider":"openai-codex"},{"message_id":3,"role":"tool","content":"project docs","tool_call_id":"call-1","tool_name":"read_file","timestamp":1787734802.0,"model":"gpt-5.6-sol","provider":"openai-codex"},{"message_id":4,"role":"assistant","content":"Done","timestamp":1787734803.0,"model":"gpt-5.6-sol","provider":"openai-codex"}]"#
        let entries = HermesTranscriptParser.parse(databaseRows: Data(rows.utf8), limit: 80)

        XCTAssertEqual(entries.map(\.kind), [.user, .tool, .assistant])
        XCTAssertEqual(entries[1].title, "Read File")
        XCTAssertTrue(entries[1].text.contains("README.md"))
        XCTAssertEqual(entries[1].detail, "project docs")
        XCTAssertEqual(entries[1].model, "openai-codex/gpt-5.6-sol")
        XCTAssertEqual(entries.last?.text, "Done")
    }

    func testPiTranscriptUsesTheActiveBranchAndKeepsTheActualModel() throws {
        let jsonl = [
            #"{"type":"session","version":3,"id":"pi-session","timestamp":"2026-08-26T09:00:00Z","cwd":"/tmp/work"}"#,
            #"{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-08-26T09:00:01Z","provider":"openai-codex","modelId":"gpt-5.6-sol"}"#,
            #"{"type":"message","id":"u1","parentId":"m1","timestamp":"2026-08-26T09:00:02Z","message":{"role":"user","content":"Build it","timestamp":1787734802000}}"#,
            #"{"type":"message","id":"a-old","parentId":"u1","timestamp":"2026-08-26T09:00:03Z","message":{"role":"assistant","content":[{"type":"text","text":"Old branch"}],"provider":"anthropic","model":"claude-old","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"stopReason":"stop","timestamp":1787734803000}}"#,
            #"{"type":"message","id":"a2","parentId":"u1","timestamp":"2026-08-26T09:00:04Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"tool-1","name":"bash","arguments":{"command":"swift test"}}],"provider":"openai-codex","model":"gpt-5.6-sol","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":0,"totalTokens":17},"stopReason":"toolUse","timestamp":1787734804000}}"#,
            #"{"type":"message","id":"r1","parentId":"a2","timestamp":"2026-08-26T09:00:05Z","message":{"role":"toolResult","toolCallId":"tool-1","toolName":"bash","content":[{"type":"text","text":"ok"}],"isError":false,"timestamp":1787734805000}}"#,
            #"{"type":"message","id":"a3","parentId":"r1","timestamp":"2026-08-26T09:00:06Z","message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"provider":"openai-codex","model":"gpt-5.6-sol","usage":{"input":4,"output":2,"cacheRead":0,"cacheWrite":0,"totalTokens":6},"stopReason":"stop","timestamp":1787734806000}}"#
        ].joined(separator: "\n")

        let snapshot = PiFamilyTranscriptParser.parse(data: Data(jsonl.utf8), limit: 80)

        XCTAssertEqual(snapshot.provider, "openai-codex")
        XCTAssertEqual(snapshot.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.totalTokens, 23)
        XCTAssertEqual(snapshot.turnState, .completed)
        XCTAssertFalse(snapshot.entries.contains { $0.text == "Old branch" })
        XCTAssertTrue(snapshot.entries.contains {
            $0.kind == .tool && $0.title == "Bash" && $0.detail == "ok" && $0.model == "gpt-5.6-sol"
        })
        XCTAssertEqual(snapshot.entries.last?.text, "Done")
        XCTAssertEqual(
            AgentTranscriptParser.parse(data: Data(jsonl.utf8), source: .pi, limit: 80),
            snapshot.entries
        )
    }

    func testOMPTitleSlotAndAgentRoleAreMetadataNotChat() throws {
        let jsonl = [
            #"{"type":"title","v":1,"title":"Ship app","source":"user","updatedAt":1787734800000,"pad":""}"#,
            #"{"type":"session","version":3,"id":"omp-session","timestamp":"2026-08-26T09:00:00Z","cwd":"/tmp/work","title":"Ship app","titleSource":"user"}"#,
            #"{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-08-26T09:00:01Z","model":"openai-codex/gpt-5.6-sol"}"#,
            #"{"type":"session_init","id":"i1","parentId":"m1","timestamp":"2026-08-26T09:00:02Z","agent":"slow","modelRole":"slow","tools":["read","task"]}"#,
            #"{"type":"message","id":"u1","parentId":"i1","timestamp":"2026-08-26T09:00:03Z","message":{"role":"user","content":[{"type":"text","text":"Review"}],"timestamp":1787734803000}}"#,
            #"{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-08-26T09:00:04Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"task-1","name":"task","arguments":{"agent":"smol","task":"check tests"}}],"provider":"openai-codex","model":"gpt-5.6-sol","usage":{"input":3,"output":2,"cacheRead":0,"cacheWrite":0},"stopReason":"toolUse","timestamp":1787734804000}}"#
        ].joined(separator: "\n")

        let snapshot = PiFamilyTranscriptParser.parse(data: Data(jsonl.utf8), limit: 80)

        XCTAssertEqual(snapshot.sessionName, "Ship app")
        XCTAssertEqual(snapshot.provider, "openai-codex")
        XCTAssertEqual(snapshot.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.agentRole, "slow")
        XCTAssertFalse(snapshot.entries.contains { $0.text.contains("title") || $0.text.contains("session_init") })
        XCTAssertTrue(snapshot.entries.contains { $0.kind == .tool && $0.title == "Task" })
    }

    func testOpenCodeChildSessionBecomesAParentAgentEvent() {
        let event = OpenCodeSSEEvent(
            event: "message",
            data: #"{"type":"session.created","properties":{"info":{"id":"ses_child","parentID":"ses_parent","title":"Research","directory":"/tmp/work"}}}"#
        )

        let mapped = OpenCodeNativeEventMapper.bridgeEvents(for: event)

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped.first?.sessionID, "ses_parent")
        XCTAssertEqual(mapped.first?.kind, .subagentStarted)
        XCTAssertEqual(mapped.first?.subagentID, "ses_child")
        XCTAssertEqual(mapped.first?.subagentType, "Research")
    }

    func testCompactSessionChipUsesOfficialHarnessMarks() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessionViews = try String(
            contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/SessionViews.swift"),
            encoding: .utf8
        )
        let notchSurface = try String(
            contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/NotchSurfaceView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sessionViews.contains("case .pi: \"PiMark\""))
        XCTAssertTrue(sessionViews.contains("case .omp: \"OMPMark\""))
        XCTAssertTrue(sessionViews.contains("case .hermes: \"HermesMark\""))
        XCTAssertTrue(notchSurface.contains("ProviderMark(source: session.key.source, size: 9)"))
        XCTAssertFalse(notchSurface.contains("TerminalAppMark(target: terminal"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repository.appendingPathComponent("Resources/Assets.xcassets/PiMark.imageset/pi.svg").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repository.appendingPathComponent("Resources/Assets.xcassets/OMPMark.imageset/omp.svg").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repository.appendingPathComponent("Resources/Assets.xcassets/HermesMark.imageset/hermes.png").path
        ))
    }

    func testBundledPiFamilyExtensionReportsModelsThemesAndAgents() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let extensionSource = try String(
            contentsOf: repository.appendingPathComponent("Integrations/noturcode-pi-extension.ts"),
            encoding: .utf8
        )
        let setupSource = try String(
            contentsOf: repository.appendingPathComponent("Sources/NoturcodeApp/IntegrationBootstrapper.swift"),
            encoding: .utf8
        )
        let hermesPlugin = try String(
            contentsOf: repository.appendingPathComponent(
                "Integrations/noturcode-hermes-plugin/__init__.py"
            ),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: repository.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        for event in ["session_start", "before_agent_start", "tool_execution_start", "tool_execution_end", "session_shutdown"] {
            XCTAssertTrue(extensionSource.contains("\"\(event)\""), event)
        }
        for option in ["--provider", "--model", "--theme", "--agent-role", "--subagent"] {
            XCTAssertTrue(extensionSource.contains(option), option)
        }
        XCTAssertTrue(extensionSource.contains("ctx.ui?.theme?.name"))
        XCTAssertTrue(extensionSource.contains("statusLineLuminance"))
        XCTAssertTrue(extensionSource.contains("let deliveryQueue = Promise.resolve()"))
        XCTAssertFalse(extensionSource.contains("detached: true"))
        XCTAssertTrue(setupSource.contains("let deliveryQueue = Promise.resolve()"))
        XCTAssertTrue(setupSource.contains("await child.exited"))
        XCTAssertTrue(setupSource.contains(".pi/agent/extensions/noturcode.ts"))
        XCTAssertTrue(setupSource.contains(".omp/agent/extensions/noturcode.ts"))
        XCTAssertTrue(setupSource.contains(".hermes/plugins/noturcode"))
        XCTAssertTrue(setupSource.contains("enableHermesPlugin"))
        for hook in ["pre_llm_call", "post_llm_call", "pre_tool_call", "post_tool_call", "subagent_start", "subagent_stop"] {
            XCTAssertTrue(hermesPlugin.contains("register_hook(\"\(hook)\""), hook)
        }
        XCTAssertTrue(hermesPlugin.contains("register_command(\n        \"nc\""))
        XCTAssertTrue(hermesPlugin.contains("_EVENTS: \"queue.Queue[list[str]]\""))
        XCTAssertFalse(hermesPlugin.contains("\"--prompt\""))
        XCTAssertFalse(hermesPlugin.contains("\"--message\""))
        XCTAssertTrue(project.contains("noturcode-pi-extension.ts"))
        XCTAssertTrue(project.contains("noturcode-hermes-plugin"))
    }
}
