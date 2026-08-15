import AppKit
import Carbon
import Foundation
import NoturcodeCore

enum ITermRevealResult: Equatable, Sendable {
    case revealed(elapsed: TimeInterval)
    case missing
    case failed(String)
}

/// Focuses one exact terminal target. Every non-iTerm adapter requires the
/// native pane/window ID captured by the hook; it never guesses from the
/// current foreground terminal.
actor ITermNavigator {
    private let compiledScript: NSAppleScript?
    private let terminalScript: NSAppleScript?
    private let ghosttyScript: NSAppleScript?
    private let compilationError: String?

    init() {
        var iTermError: NSDictionary?
        if let script = NSAppleScript(source: ITermNavigationScript.source),
           script.compileAndReturnError(&iTermError) {
            compiledScript = script
            compilationError = nil
        } else {
            compiledScript = nil
            compilationError = iTermError?[NSAppleScript.errorMessage] as? String
                ?? "Noturcode could not compile iTerm2 navigation."
        }

        if let terminal = NSAppleScript(source: Self.terminalNavigationSource) {
            var error: NSDictionary?
            terminalScript = terminal.compileAndReturnError(&error) ? terminal : nil
        } else {
            terminalScript = nil
        }
        if Self.ghosttyIsInstalled,
           let ghostty = NSAppleScript(source: Self.ghosttyNavigationSource) {
            var error: NSDictionary?
            ghosttyScript = ghostty.compileAndReturnError(&error) ? ghostty : nil
        } else {
            ghosttyScript = nil
        }
    }

    private static var ghosttyIsInstalled: Bool {
        let fileManager = FileManager.default
        let paths = [
            "/Applications/Ghostty.app",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ghostty.app").path
        ]
        return paths.contains(where: fileManager.fileExists(atPath:))
    }

    func reveal(_ target: TerminalTarget) -> ITermRevealResult {
        let started = Date()
        guard let identity = target.identity else {
            return revealITerm(target, started: started)
        }

        if let multiplexer = identity.multiplexer {
            switch multiplexer {
            case .tmux:
                return revealTmux(identity, started: started)
            case .zellij:
                return revealZellij(identity, started: started)
            }
        }

        switch target.applicationKind {
        case .iterm:
            return revealITerm(target, started: started)
        case .terminal:
            return revealTerminal(identity, started: started)
        case .wezterm:
            return revealWezTerm(identity, started: started)
        case .ghostty:
            return revealGhostty(identity, started: started)
        case .kitty:
            return revealKitty(identity, started: started)
        case .warp:
            return activateApplication(.warp, started: started)
        case .unknown:
            return .failed("Noturcode does not know which terminal owns this session.")
        }
    }

    private func revealITerm(_ target: TerminalTarget, started: Date) -> ITermRevealResult {
        guard let compiledScript else {
            return .failed(compilationError ?? "Noturcode could not prepare iTerm2 navigation.")
        }
        let event = appleEvent(handler: "navigate", arguments: [target.uniqueID, target.tty ?? ""])
        var error: NSDictionary?
        let result = compiledScript.executeAppleEvent(event, error: &error).stringValue
        if let error {
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "iTerm2 session navigation failed.")
        }
        switch result {
        case "FOUND": return .revealed(elapsed: Date().timeIntervalSince(started))
        case "MISSING": return .missing
        default: return .failed("iTerm2 did not focus the requested split.")
        }
    }

    private func revealTerminal(_ identity: TerminalIdentity, started: Date) -> ITermRevealResult {
        guard let tty = identity.tty, let terminalScript else { return .missing }
        let event = appleEvent(handler: "navigateTerminal", arguments: [tty])
        var error: NSDictionary?
        let result = terminalScript.executeAppleEvent(event, error: &error).stringValue
        if let error {
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "Terminal navigation failed.")
        }
        return result == "FOUND"
            ? .revealed(elapsed: Date().timeIntervalSince(started))
            : .missing
    }

    private func revealWezTerm(_ identity: TerminalIdentity, started: Date) -> ITermRevealResult {
        guard let pane = identity.weztermPane,
              let socket = identity.weztermUnixSocket,
              !socket.isEmpty else { return .missing }
        let result = runCommand(
            "wezterm",
            arguments: ["cli", "activate-pane", "--pane-id", pane],
            environment: ["WEZTERM_UNIX_SOCKET": socket]
        )
        return commandResult(result, started: started, failure: "WezTerm did not focus the requested pane.")
    }

    private func revealGhostty(_ identity: TerminalIdentity, started: Date) -> ITermRevealResult {
        guard let ghosttyScript,
              identity.tty != nil || identity.processID != nil else { return .missing }
        let event = appleEvent(
            handler: "focusGhostty",
            arguments: [identity.tty ?? "", identity.processID.map(String.init) ?? ""]
        )
        var error: NSDictionary?
        let result = ghosttyScript.executeAppleEvent(event, error: &error).stringValue
        if let error {
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "Ghostty navigation failed.")
        }
        return result == "FOUND"
            ? .revealed(elapsed: Date().timeIntervalSince(started))
            : .missing
    }

    private func revealKitty(_ identity: TerminalIdentity, started: Date) -> ITermRevealResult {
        guard let windowID = identity.kittyWindowID,
              let socket = identity.kittyRemoteSocket,
              !socket.isEmpty else { return .missing }
        let result = runCommand(
            "kitten",
            arguments: ["@", "--to", socket, "focus-window", "--match", "id:\(windowID)"]
        )
        return commandResult(result, started: started, failure: "kitty did not focus the requested window.")
    }

    private func revealTmux(_ identity: TerminalIdentity, started: Date) -> ITermRevealResult {
        guard let pane = identity.tmuxPane,
              let socket = identity.tmuxSocket,
              !socket.isEmpty else { return .missing }
        let result = runCommand("tmux", arguments: ["-S", socket, "select-pane", "-t", pane])
        guard case .success = result else {
            return commandResult(result, started: started, failure: "tmux did not focus the requested pane.")
        }
        // tmux selects the pane in its server. Bring the known host terminal
        // to the front only after that exact pane selection succeeds.
        return activateApplication(identity.application, started: started)
    }

    private func revealZellij(_ identity: TerminalIdentity, started: Date) -> ITermRevealResult {
        guard let session = identity.zellijSessionName,
              !session.isEmpty,
              let pane = identity.zellijPaneID,
              !pane.isEmpty else { return .missing }
        let result = runCommand(
            "zellij",
            arguments: ["--session", session, "action", "focus-pane-id", pane]
        )
        guard case .success = result else {
            return commandResult(result, started: started, failure: "Zellij did not focus the requested pane.")
        }
        return activateApplication(identity.application, started: started)
    }

    private func activateApplication(_ kind: TerminalApplicationKind, started: Date) -> ITermRevealResult {
        guard let bundleIdentifier = kind.bundleIdentifier else {
            return .failed("Noturcode cannot identify this terminal app.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
                ? .revealed(elapsed: Date().timeIntervalSince(started))
                : .failed("Could not open \(kind.displayName).")
        } catch {
            return .failed("Could not open \(kind.displayName): \(error.localizedDescription)")
        }
    }

    private enum CommandResult {
        case success
        case failure(String)
    }

    private func commandResult(_ result: CommandResult, started: Date, failure: String) -> ITermRevealResult {
        switch result {
        case .success: return .revealed(elapsed: Date().timeIntervalSince(started))
        case let .failure(message): return .failed(message.isEmpty ? failure : message)
        }
    }

    private func runCommand(
        _ command: String,
        arguments: [String],
        environment overrides: [String: String] = [:]
    ) -> CommandResult {
        let process = Process()
        let directCandidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            command == "wezterm" ? "/Applications/WezTerm.app/Contents/MacOS/wezterm" : nil,
            command == "kitten" ? "/Applications/kitty.app/Contents/MacOS/kitten" : nil,
            "/Applications/\(command).app/Contents/MacOS/\(command)"
        ].compactMap { $0 }
        if let path = directCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        var environment = ProcessInfo.processInfo.environment
        overrides.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 ? .success : .failure(text)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func appleEvent(handler: String, arguments values: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        for (index, value) in values.enumerated() {
            arguments.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    private static let terminalNavigationSource = """
    on navigateTerminal(targetTTY)
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if (tty of terminalTab as text) is (targetTTY as text) then
                        set selected of terminalTab to true
                        set index of terminalWindow to 1
                        activate
                        return "FOUND"
                    end if
                end repeat
            end repeat
        end tell
        return "MISSING"
    end navigateTerminal
    """

    private static let ghosttyNavigationSource = """
    on focusGhostty(targetTTY, targetPID)
        tell application "Ghostty"
            repeat with terminalSurface in terminals
                if (targetTTY as text) is not "" and (tty of terminalSurface as text) is (targetTTY as text) then
                    focus terminalSurface
                    return "FOUND"
                end if
                if (targetPID as text) is not "" and (pid of terminalSurface as text) is (targetPID as text) then
                    focus terminalSurface
                    return "FOUND"
                end if
            end repeat
        end tell
        return "MISSING"
    end focusGhostty
    """
}
