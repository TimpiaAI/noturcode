import AppKit
import NoturcodeCore
import SwiftUI

@main
struct NoturcodeApplication: App {
    @NSApplicationDelegateAdaptor(NoturcodeAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
                .frame(width: 1, height: 1)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Noturcode") {
                    AppModel.shared.showStatusWindow()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Show Status") {
                    AppModel.shared.showStatusWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])
                Button("Set Up or Repair Integrations…") {
                    IntegrationBootstrapper.shared.repairAndShowResult()
                }
            }
        }
    }
}

@MainActor
final class NoturcodeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let dockIcon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = dockIcon
        }

        if CommandLine.arguments.contains("--iterm-prompt-self-test") {
            let result = ITermPromptSender().send(
                "__NO_SEND__",
                to: TerminalTarget(sessionID: "__NOTURCODE_NONEXISTENT_SESSION__")
            )
            switch result {
            case .sent: print("ITERM_PROMPT_SELF_TEST:SENT")
            case .missing: print("ITERM_PROMPT_SELF_TEST:MISSING")
            case let .failed(message): print("ITERM_PROMPT_SELF_TEST:FAILED:\(message)")
            }
            NSApplication.shared.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--iterm-navigation-self-test") {
            let result = ITermNavigator().reveal(
                TerminalTarget(sessionID: "__NOTURCODE_NONEXISTENT_SESSION__")
            )
            switch result {
            case .revealed: print("ITERM_NAVIGATION_SELF_TEST:REVEALED")
            case .missing: print("ITERM_NAVIGATION_SELF_TEST:MISSING")
            case let .failed(message): print("ITERM_NAVIGATION_SELF_TEST:FAILED:\(message)")
            }
            NSApplication.shared.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--iterm-pane-geometry-self-test") {
            if let frame = ITermPaneGeometryResolver().focusedPaneFrame() {
                print("ITERM_PANE_GEOMETRY_SELF_TEST:PASS:\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))")
            } else {
                print("ITERM_PANE_GEOMETRY_SELF_TEST:MISSING")
            }
            NSApplication.shared.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--iterm-pane-highlight-self-test") {
            if let frame = ITermPaneGeometryResolver().focusedPaneFrame() {
                let now = Date()
                let session = TrackedSession(
                    key: SessionKey(source: .codex, sessionID: "pane-highlight-self-test"),
                    name: "Focused iTerm pane",
                    terminal: TerminalTarget(sessionID: "pane-highlight-self-test"),
                    sourceProcessID: nil,
                    cwd: nil,
                    connectedAt: now,
                    lastPromptAt: now,
                    stateChangedAt: now
                )
                let coordinator = TerminalPaneHighlightCoordinator()
                coordinator.show(frame: frame, session: session)
                objc_setAssociatedObject(NSApplication.shared, "pane-highlight-self-test", coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                print("ITERM_PANE_HIGHLIGHT_SELF_TEST:PASS:\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                print("ITERM_PANE_HIGHLIGHT_SELF_TEST:MISSING")
                NSApplication.shared.terminate(nil)
            }
            return
        }

        if let flag = CommandLine.arguments.firstIndex(of: "--integration-self-test"),
           CommandLine.arguments.indices.contains(flag + 1) {
            let home = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
            let report = IntegrationBootstrapper.shared.install(home: home,
                                                                 payload: Bundle.main.resourceURL?.appendingPathComponent("IntegrationPayload"))
            print("INTEGRATION_SELF_TEST:\(report.isHealthy ? "PASS" : "FAIL")")
            print("INTEGRATION_DETECTED:\(report.integrations.filter(\.detected).map(\.id).joined(separator: ","))")
            for error in report.errors { print("INTEGRATION_ERROR:\(error)") }
            NSApplication.shared.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--ui-test-desktop") {
            AppModel.shared.start()
            AppModel.shared.showStatusWindow()
            return
        }

        AppModel.shared.start()

        let isBackgroundLaunch = CommandLine.arguments.contains("--background")
        if !isBackgroundLaunch {
            AppModel.shared.showStatusWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showStatusWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}
