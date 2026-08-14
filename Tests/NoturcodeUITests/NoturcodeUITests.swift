import AppKit
import XCTest

@MainActor
final class NoturcodeUITests: XCTestCase {
    @MainActor
    func testDesktopConversationFirstWorkspace() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-ui-desktop-\(ProcessInfo.processInfo.processIdentifier).json")
        let fixture = """
        [{
          "key":{"source":"codex","sessionID":"desktop-chat"},
          "name":"noda",
          "terminal":{"sessionID":"w0t1p1:DESKTOP-CHAT"},
          "cwd":"/tmp/noda",
          "state":"working",
          "connectedAt":"2026-08-13T10:00:00Z",
          "lastPromptAt":"2026-08-13T10:01:00Z",
          "stateChangedAt":"2026-08-13T10:01:00Z",
          "lastAgentMessage":"Noturcode summary\\nDone: old response\\nNeeds you: old request",
          "currentActivity":"Editing the chat shell",
          "activityStartedAt":"2026-08-13T10:01:00Z",
          "recentActivities":[],"subagents":[]
        }]
        """
        try Data(fixture.utf8).write(to: stateURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-desktop-\(ProcessInfo.processInfo.processIdentifier).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--ui-test-desktop"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["desktop-session-sidebar"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["desktop-workspace"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["prompt-composer"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["workflow-sidebar"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Needs you: old request"].exists)
        app.descendants(matching: .any)["toggle-desktop-workflow"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["workflow-sidebar"].firstMatch.waitForExistence(timeout: 2))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDockLaunchShowsStatusGlanceAndLoginControl() {
        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-\(ProcessInfo.processInfo.processIdentifier).sock"
        app.launch()
        XCTAssertTrue(app.windows["Noturcode"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Noturcode"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["open-at-login-toggle"].exists)
        XCTAssertGreaterThanOrEqual(app.windows["Noturcode"].frame.width, 860)
        XCTAssertGreaterThanOrEqual(app.windows["Noturcode"].frame.height, 560)
    }

    @MainActor
    func testDisconnectButtonRemovesOnlyTheNoturcodeCard() throws {
        let suffix = ProcessInfo.processInfo.processIdentifier
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-ui-disconnect-\(suffix).json")
        let fixture = """
        [{
          "key":{"source":"codex","sessionID":"ui-disconnect"},
          "name":"keep-terminal-running",
          "terminal":{"sessionID":"w0t1p2:UI-DISCONNECT"},
          "cwd":"/tmp",
          "state":"working",
          "connectedAt":"2026-08-13T00:00:00Z",
          "lastPromptAt":"2026-08-13T00:00:00Z",
          "stateChangedAt":"2026-08-13T00:00:00Z",
          "lastAgentMessage":"Still running outside Noturcode",
          "recentActivities":[],"subagents":[]
        }]
        """
        try Data(fixture.utf8).write(to: stateURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-disconnect-\(suffix).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--background", "--ui-test-expanded", "--ui-test-hover-first"]
        app.launch()

        let disconnect = app.descendants(matching: .any)["disconnect-noturcode-codex:ui-disconnect"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 3))
        disconnect.click()
        XCTAssertFalse(disconnect.waitForExistence(timeout: 1))

        let persisted = try Data(contentsOf: stateURL)
        let sessions = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [Any])
        XCTAssertTrue(sessions.isEmpty)
    }

    @MainActor
    func testWorkflowAgentOpensItsOwnConversationThread() throws {
        let suffix = ProcessInfo.processInfo.processIdentifier
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-ui-agent-thread-\(suffix).json")
        let fixture = """
        [{
          "key":{"source":"claude","sessionID":"ui-agent-thread"},
          "name":"agent-inbox",
          "terminal":{"sessionID":"w0t1p2:UI-AGENT-THREAD"},
          "cwd":"/tmp",
          "state":"working",
          "connectedAt":"2026-08-13T00:00:00Z",
          "lastPromptAt":"2026-08-13T00:00:00Z",
          "stateChangedAt":"2026-08-13T00:00:00Z",
          "lastAgentMessage":"Parent conversation remains available.",
          "recentActivities":[],
          "subagents":[{
            "id":"a1","type":"researcher","state":"working",
            "activity":"Inspect the selected component",
            "startedAt":"2026-08-13T00:00:00Z","updatedAt":"2026-08-13T00:00:01Z",
            "tokens":120,"lastMessage":null
          }]
        }]
        """
        try Data(fixture.utf8).write(to: stateURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-agent-thread-\(suffix).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--ui-test-desktop", "--ui-test-agent-conversation"]
        app.launch()
        app.activate()

        let workspace = app.descendants(matching: .any)["desktop-workspace"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["workflow-sidebar"].firstMatch.waitForExistence(timeout: 3))
        let agentThread = app.descendants(matching: .any)["workflow-node-subagent-a1"].firstMatch
        XCTAssertTrue(agentThread.waitForExistence(timeout: 3))
        agentThread.click()
        XCTAssertTrue(app.staticTexts["This is the selected agent's own conversation."].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["return-to-session-chat"].firstMatch.exists)

        let parentThread = app.descendants(matching: .any)["workflow-node-session"].firstMatch
        XCTAssertTrue(parentThread.exists)
        parentThread.click()
        XCTAssertTrue(app.staticTexts["The compact glass card is ready. The attached reference stays available for preview."].waitForExistence(timeout: 2))
    }

    @MainActor
    func testCommandVPastesClipboardImageIntoChatComposer() throws {
        let suffix = ProcessInfo.processInfo.processIdentifier
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-ui-image-paste-\(suffix).json")
        let fixture = """
        [{
          "key":{"source":"codex","sessionID":"ui-image-paste"},
          "name":"image-paste",
          "terminal":{"sessionID":"w0t1p2:UI-IMAGE-PASTE"},
          "cwd":"/tmp",
          "state":"working",
          "connectedAt":"2026-08-13T00:00:00Z",
          "lastPromptAt":"2026-08-13T00:00:00Z",
          "stateChangedAt":"2026-08-13T00:00:00Z",
          "lastAgentMessage":"Waiting for reference image",
          "recentActivities":[],"subagents":[],"staleTargetMessage":null
        }]
        """
        try Data(fixture.utf8).write(to: stateURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 24)).fill()
        image.unlockFocus()
        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-image-paste-\(suffix).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--background", "--ui-test-expanded", "--ui-test-hover-first"]
        app.launch()

        let viewChat = app.descendants(matching: .any)["view-terminal-codex:ui-image-paste"].firstMatch
        XCTAssertTrue(viewChat.waitForExistence(timeout: 3))
        viewChat.click()
        let composer = app.descendants(matching: .any)["prompt-composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.50)).click()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([image]))
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["prompt-image-attachment"].firstMatch.waitForExistence(timeout: 2))

        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([image]))
        composer.typeKey("v", modifierFlags: .option)
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "prompt-image-attachment").count,
            2
        )
    }

    func testHoverKeepsSessionNavigationCleanAndButtonOpensPersistentTerminal() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-ui-spotlight-\(ProcessInfo.processInfo.processIdentifier).json")
        let fixture = """
        [{
          "key":{"source":"claude","sessionID":"ui-spotlight"},
          "name":"demo-workspace",
          "terminal":{"sessionID":"w0t1p2:UI-SPOTLIGHT"},
          "sourceProcessID":null,
          "cwd":"/tmp/noturcode-demo",
          "state":"working",
          "connectedAt":"2026-08-12T20:00:00Z",
          "lastPromptAt":"2026-08-12T20:00:00Z",
          "stateChangedAt":"2026-08-12T20:00:00Z",
          "lastAgentMessage":"Reviewing the exact notch composition.",
          "tokens":4289,
          "currentActivity":"Read · Sources/NoturcodeApp/SessionViews.swift",
          "activityStartedAt":"2026-08-12T20:00:00Z",
          "recentActivities":[
            {"id":"t1","label":"Read · SessionViews.swift","startedAt":"2026-08-12T20:00:00Z","finishedAt":"2026-08-12T20:00:01Z"},
            {"id":"t2","label":"Read · DisplayCoordinator.swift","startedAt":"2026-08-12T20:00:02Z","finishedAt":"2026-08-12T20:00:03Z"},
            {"id":"t3","label":"Edit · FluidMarble.metal","startedAt":"2026-08-12T20:00:04Z","finishedAt":"2026-08-12T20:00:05Z"},
            {"id":"t4","label":"Command · xcodebuild test","startedAt":"2026-08-12T20:00:06Z","finishedAt":"2026-08-12T20:00:07Z"},
            {"id":"t5","label":"Image · inspect accessibility","startedAt":"2026-08-12T20:00:08Z","finishedAt":"2026-08-12T20:00:09Z"},
            {"id":"t6","label":"Command · capture screenshot","startedAt":"2026-08-12T20:00:10Z","finishedAt":null}
          ],
          "subagents":[
            {"id":"a1","type":"tool","state":"done","activity":"Read SessionViews.swift","startedAt":"2026-08-12T20:00:00Z","updatedAt":"2026-08-12T20:00:01Z","tokens":120,"lastMessage":null},
            {"id":"a2","type":"tool","state":"done","activity":"Read DisplayCoordinator.swift","startedAt":"2026-08-12T20:00:02Z","updatedAt":"2026-08-12T20:00:03Z","tokens":180,"lastMessage":null},
            {"id":"a3","type":"tool","state":"done","activity":"Build Metal shader","startedAt":"2026-08-12T20:00:04Z","updatedAt":"2026-08-12T20:00:05Z","tokens":240,"lastMessage":null},
            {"id":"a4","type":"tool","state":"done","activity":"Run core tests","startedAt":"2026-08-12T20:00:06Z","updatedAt":"2026-08-12T20:00:07Z","tokens":90,"lastMessage":null},
            {"id":"a5","type":"tool","state":"done","activity":"Inspect accessibility","startedAt":"2026-08-12T20:00:08Z","updatedAt":"2026-08-12T20:00:09Z","tokens":75,"lastMessage":null},
            {"id":"a6","type":"tool","state":"done","activity":"Capture screenshot","startedAt":"2026-08-12T20:00:10Z","updatedAt":"2026-08-12T20:00:11Z","tokens":60,"lastMessage":null}
          ],
          "staleTargetMessage":null
        }]
        """
        try Data(fixture.utf8).write(to: stateURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-spotlight-\(ProcessInfo.processInfo.processIdentifier).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--background", "--ui-test-expanded", "--ui-test-hover-first"]
        app.launch()

        let sessionRow = app.descendants(matching: .any)["session-row-claude:ui-spotlight"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["activity-expand-claude:ui-spotlight"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["activity-scroll-claude:ui-spotlight"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label == 'done'")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["session-spotlight"].firstMatch.exists)

        let activityAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        activityAttachment.name = "Noturcode hover session navigation without activity log"
        activityAttachment.lifetime = .keepAlways
        add(activityAttachment)

        let viewTerminal = app.descendants(matching: .any)["view-terminal-claude:ui-spotlight"].firstMatch
        XCTAssertTrue(viewTerminal.waitForExistence(timeout: 2))
        viewTerminal.click()
        let terminalCard = app.descendants(matching: .any)["terminal-window-content"].firstMatch
        XCTAssertTrue(terminalCard.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["chat-transcript"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["chat-message-user"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat-message-assistant"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat-markdown-block"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat-code-block"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat-ascii-diagram"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["workflow-sidebar"].firstMatch.exists)
        let promptMarker = app.descendants(matching: .any)["prompt-rail-marker"].firstMatch
        XCTAssertTrue(promptMarker.exists)
        promptMarker.hover()
        XCTAssertTrue(app.descendants(matching: .any)["prompt-rail-preview"].firstMatch.waitForExistence(timeout: 2))
        promptMarker.click()
        let toggleSidebar = app.descendants(matching: .any)["toggle-chat-sidebar"].firstMatch
        XCTAssertTrue(toggleSidebar.exists)
        let closeSidebar = app.buttons["Close workflow sidebar"].firstMatch
        XCTAssertTrue(closeSidebar.exists)
        closeSidebar.click()
        let sidebar = app.descendants(matching: .any)["workflow-sidebar"].firstMatch
        let sidebarHidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sidebar)
        wait(for: [sidebarHidden], timeout: 2)
        let showSidebar = app.buttons["Show workflow sidebar"].firstMatch
        XCTAssertTrue(showSidebar.waitForExistence(timeout: 2))
        showSidebar.click()
        XCTAssertTrue(app.descendants(matching: .any)["workflow-sidebar"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'workflow-node-'"))
                .count,
            2
        )
        XCTAssertTrue(app.staticTexts["claude-sonnet-4-5"].exists)
        let agentThread = app.descendants(matching: .any)["workflow-node-subagent-a1"].firstMatch
        XCTAssertTrue(agentThread.exists)
        agentThread.click()
        XCTAssertTrue(app.staticTexts["This is the selected agent's own conversation."].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["return-to-session-chat"].firstMatch.exists)
        let parentThread = app.descendants(matching: .any)["workflow-node-session"].firstMatch
        XCTAssertTrue(parentThread.exists)
        parentThread.click()
        XCTAssertTrue(app.staticTexts["The compact glass card is ready. The attached reference stays available for preview."].waitForExistence(timeout: 2))
        let fileReference = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Preview '")).firstMatch
        XCTAssertTrue(fileReference.exists)
        let toolBatch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Expand tool batch:'")).firstMatch
        XCTAssertTrue(toolBatch.exists)
        let dragHandle = app.descendants(matching: .any)["terminal-drag-handle"].firstMatch
        XCTAssertTrue(dragHandle.exists)
        XCTAssertTrue(app.descendants(matching: .any)["resize-affordances"].firstMatch.exists)
        let composer = app.descendants(matching: .any)["prompt-composer"].firstMatch
        XCTAssertTrue(composer.exists)
        XCTAssertTrue(app.descendants(matching: .any)["attach-images"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["paste-images"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["session-summary-card"].firstMatch.exists)
        let compact = app.descendants(matching: .any)["compact-session"].firstMatch
        XCTAssertTrue(compact.exists)
        compact.click()
        XCTAssertTrue(app.staticTexts["Compaction requested"].waitForExistence(timeout: 1))
        let sendPrompt = app.descendants(matching: .any)["send-prompt"].firstMatch
        XCTAssertTrue(sendPrompt.exists)
        composer.click()
        composer.typeText("Check this exact component")
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 1))

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Noturcode persistent session chat and workflow"
        attachment.lifetime = .keepAlways
        add(attachment)

        let closePreview = app.descendants(matching: .any)["close-terminal-preview"].firstMatch
        XCTAssertTrue(closePreview.exists)
        closePreview.click()
        XCTAssertFalse(terminalCard.waitForExistence(timeout: 1))
    }

    func testRapidSessionHoverSettlesOnOnlyTheLatestRow() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-ui-hover-switch-\(ProcessInfo.processInfo.processIdentifier).json")
        let fixture = """
        [
          {
            "key":{"source":"codex","sessionID":"hover-one"},
            "name":"first-session",
            "terminal":{"sessionID":"w0t1p1:HOVER-ONE"},
            "cwd":"/tmp/first",
            "state":"working",
            "connectedAt":"2026-08-12T20:00:00Z",
            "lastPromptAt":"2026-08-12T20:01:00Z",
            "stateChangedAt":"2026-08-12T20:00:00Z",
            "lastAgentMessage":"Inspecting the first session.",
            "recentActivities":[{"id":"one","label":"Search web","startedAt":"2026-08-12T20:00:00Z","finishedAt":null}],
            "subagents":[],"staleTargetMessage":null
          },
          {
            "key":{"source":"claude","sessionID":"hover-two"},
            "name":"second-session",
            "terminal":{"sessionID":"w0t1p2:HOVER-TWO"},
            "cwd":"/tmp/second",
            "state":"working",
            "connectedAt":"2026-08-12T20:00:00Z",
            "lastPromptAt":"2026-08-12T20:00:00Z",
            "stateChangedAt":"2026-08-12T20:00:00Z",
            "lastAgentMessage":"Inspecting the second session.",
            "recentActivities":[{"id":"two","label":"Edit files","startedAt":"2026-08-12T20:00:00Z","finishedAt":null}],
            "subagents":[],"staleTargetMessage":null
          }
        ]
        """
        try Data(fixture.utf8).write(to: stateURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-hover-switch-\(ProcessInfo.processInfo.processIdentifier).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--background", "--ui-test-expanded", "--ui-test-rapid-hover"]
        app.launch()

        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "first-session"))
            .firstMatch
        let secondRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "second-session"))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 2))
        XCTAssertTrue(secondRow.exists)
        XCTAssertFalse(app.descendants(matching: .any)["activity-scroll-claude:hover-two"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["activity-scroll-codex:hover-one"].firstMatch.exists)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Rapid hover keeps session rows free of activity logs"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDoneSummaryHoverShowsResponseScopedSteps() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-ui-done-summary-\(ProcessInfo.processInfo.processIdentifier).json")
        let fixture = """
        [{
          "key":{"source":"codex","sessionID":"done-hover"},
          "name":"summary-preview",
          "terminal":{"sessionID":"w0t1p1:DONE-HOVER"},
          "cwd":"/tmp/summary",
          "state":"done",
          "connectedAt":"2026-08-12T20:00:00Z",
          "lastPromptAt":"2026-08-12T20:01:00Z",
          "stateChangedAt":"2026-08-12T20:02:00Z",
          "lastAgentMessage":"Noturcode completion map\\n```text\\n+---------+     +----------+\\n| POPOVER | --> | VERIFIED |\\n+---------+     +----------+\\n```\\nNoturcode summary\\nDone: [x] Fixed hover summary -> [x] Verified response timeline\\nNeeds you: Nothing.",
          "recentActivities":[
            {"id":"old","label":"Old response","startedAt":"2026-08-12T20:00:30Z","finishedAt":"2026-08-12T20:00:31Z"},
            {"id":"current","label":"Verify summary popover","startedAt":"2026-08-12T20:01:10Z","finishedAt":"2026-08-12T20:01:11Z"}
          ],
          "subagents":[]
        }]
        """
        try Data(fixture.utf8).write(to: stateURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-done-summary-\(ProcessInfo.processInfo.processIdentifier).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--background", "--ui-test-expanded", "--ui-test-hover-first"]
        app.launch()

        let done = app.descendants(matching: .any)["done-summary-codex:done-hover"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.hover()
        let popover = app.descendants(matching: .any)["done-summary-popover-codex:done-hover"].firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["done-summary-ascii-map-codex:done-hover"].firstMatch.exists)
        let steps = app.descendants(matching: .any)["done-summary-steps-codex:done-hover"].firstMatch
        XCTAssertTrue(steps.waitForExistence(timeout: 1))
        let responseSteps = steps.label
        XCTAssertTrue(responseSteps.contains("Verify summary popover"), "response steps: \(responseSteps)")
        XCTAssertFalse(responseSteps.contains("Old response"))
    }

    @MainActor
    func testWorkingSessionHidesPreviousDoneAndNeedsYouSummary() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-ui-working-summary-\(ProcessInfo.processInfo.processIdentifier).json")
        let fixture = """
        [{
          "key":{"source":"codex","sessionID":"working-summary"},
          "name":"still-working",
          "terminal":{"sessionID":"w0t1p1:WORKING-SUMMARY"},
          "cwd":"/tmp/working-summary",
          "state":"working",
          "connectedAt":"2026-08-13T10:00:00Z",
          "lastPromptAt":"2026-08-13T10:01:00Z",
          "stateChangedAt":"2026-08-13T10:01:00Z",
          "lastAgentMessage":"Noturcode summary\\nDone: [x] Previous response -> [x] Verified\\nNeeds you: Old request",
          "currentActivity":"Reading current files",
          "activityStartedAt":"2026-08-13T10:01:00Z",
          "recentActivities":[],"subagents":[]
        }]
        """
        try Data(fixture.utf8).write(to: stateURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stateURL) }

        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-working-summary-\(ProcessInfo.processInfo.processIdentifier).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--background", "--ui-test-expanded", "--ui-test-hover-first"]
        app.launch()

        let row = app.descendants(matching: .any)["session-row-codex:working-summary"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["done-summary-codex:working-summary"].firstMatch.exists)
        XCTAssertTrue(row.label.contains("working"))
        XCTAssertFalse(row.label.contains("Needs you: Old request"))
    }

    func testOpenChatReceivesTranscriptWritesWithoutHoverOrRefocus() throws {
        let suffix = ProcessInfo.processInfo.processIdentifier
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-live-chat-\(suffix)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("live.jsonl")
        let stateURL = directory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initial = #"{"type":"assistant","timestamp":"2026-08-13T00:00:00Z","message":{"role":"assistant","model":"claude-opus-4-1","content":"Initial live marker"}}"# + "\n"
        try Data(initial.utf8).write(to: transcriptURL)
        let fixture = """
        [{
          "key":{"source":"claude","sessionID":"ui-live-chat"},
          "name":"live-chat",
          "terminal":{"sessionID":"w0t1p2:UI-LIVE-CHAT"},
          "cwd":"\(directory.path)",
          "transcriptPath":"\(transcriptURL.path)",
          "state":"working",
          "connectedAt":"2026-08-13T00:00:00Z",
          "lastPromptAt":"2026-08-13T00:00:00Z",
          "stateChangedAt":"2026-08-13T00:00:00Z",
          "lastAgentMessage":"Working live",
          "recentActivities":[],"subagents":[],"staleTargetMessage":null
        }]
        """
        try Data(fixture.utf8).write(to: stateURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let app = XCUIApplication()
        app.launchEnvironment["NOTURCODE_SOCKET_PATH"] = "/tmp/noturcode-ui-live-chat-\(suffix).sock"
        app.launchEnvironment["NOTURCODE_STATE_PATH"] = stateURL.path
        app.launchArguments = ["--background", "--ui-test-expanded", "--ui-test-live-transcript"]
        app.launch()

        let viewChat = app.descendants(matching: .any)["view-terminal-claude:ui-live-chat"].firstMatch
        XCTAssertTrue(viewChat.waitForExistence(timeout: 3))
        viewChat.click()
        let initialMessage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'chat-message-assistant' AND label CONTAINS %@", "Initial live marker"))
            .firstMatch
        XCTAssertTrue(initialMessage.waitForExistence(timeout: 2))

        let appended = #"{"type":"assistant","timestamp":"2026-08-13T00:00:01Z","message":{"role":"assistant","model":"claude-opus-4-1","content":"Streamed without hover"}}"# + "\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.synchronize()
        try handle.close()

        let streamedMessage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'chat-message-assistant' AND label CONTAINS %@", "Streamed without hover"))
            .firstMatch
        XCTAssertTrue(streamedMessage.waitForExistence(timeout: 0.9))
    }
}
