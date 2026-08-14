import AppKit
import Carbon
import Foundation
import NoturcodeCore

enum ITermPromptResult: Equatable, Sendable {
    case sent
    case missing
    case failed(String)
}

/// Sends user-confirmed text to one exact terminal target. The fixture guard
/// runs before every adapter so tests can never write to a real session.
actor ITermPromptSender {
    private let compiledScript: NSAppleScript?
    private let terminalScript: NSAppleScript?
    private let ghosttyScript: NSAppleScript?
    private let compilationError: String?
    private let usesFixture: Bool
    private let resolver = ITermSessionResolver()

    init() {
        usesFixture = CommandLine.arguments.contains("--ui-test-hover-first")
        guard !usesFixture else {
            compiledScript = nil
            terminalScript = nil
            ghosttyScript = nil
            compilationError = nil
            return
        }
        guard let script = NSAppleScript(source: ITermPromptScript.source) else {
            compiledScript = nil
            terminalScript = nil
            ghosttyScript = nil
            compilationError = "Prompt sender could not be prepared."
            return
        }
        var error: NSDictionary?
        if script.compileAndReturnError(&error) {
            compiledScript = script
            compilationError = nil
        } else {
            compiledScript = nil
            compilationError = error?[NSAppleScript.errorMessage] as? String
                ?? "Prompt sender could not be compiled."
        }
        if let terminal = NSAppleScript(source: Self.terminalPromptSource) {
            var terminalError: NSDictionary?
            terminalScript = terminal.compileAndReturnError(&terminalError) ? terminal : nil
        } else {
            terminalScript = nil
        }
        if Self.ghosttyIsInstalled,
           let ghostty = NSAppleScript(source: Self.ghosttyPromptSource) {
            var ghosttyError: NSDictionary?
            ghosttyScript = ghostty.compileAndReturnError(&ghosttyError) ? ghostty : nil
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

    func send(_ prompt: String, to target: TerminalTarget, sourceProcessID: Int32? = nil) async -> ITermPromptResult {
        if usesFixture { return .sent }
        let first = sendExact(prompt, to: target)
        guard case .missing = first,
              target.applicationKind == .iterm,
              target.multiplexer == nil,
              let sourceProcessID,
              let rebound = await resolver.resolve(processID: sourceProcessID),
              rebound != target else { return first }
        return sendExact(prompt, to: rebound)
    }

    private func sendExact(_ prompt: String, to target: TerminalTarget) -> ITermPromptResult {
        guard let identity = target.identity else {
            return sendToITerm(prompt, target: target)
        }
        if let multiplexer = identity.multiplexer {
            switch multiplexer {
            case .tmux: return sendToTmux(prompt, identity: identity)
            case .zellij: return sendToZellij(prompt, identity: identity)
            }
        }
        if target.applicationKind == .terminal {
            return sendToTerminal(prompt, identity: identity)
        }
        switch identity.application {
        case .iterm: return sendToITerm(prompt, target: target)
        case .terminal: return .missing
        case .wezterm: return sendToWezTerm(prompt, identity: identity)
        case .ghostty: return sendToGhostty(prompt, identity: identity)
        case .kitty: return sendToKitty(prompt, identity: identity)
        case .warp, .unknown:
            return .failed("Sending from Noturcode is not available for \(identity.application.displayName) yet.")
        }
    }

    private func sendToITerm(_ prompt: String, target: TerminalTarget) -> ITermPromptResult {
        guard let compiledScript else {
            return .failed(compilationError ?? "Prompt sender is unavailable.")
        }
        let event = appleEvent(handler: "submitPrompt", arguments: [target.uniqueID, prompt])
        var error: NSDictionary?
        let result = compiledScript.executeAppleEvent(event, error: &error).stringValue
        if let error { return .failed(Self.userFacingError(error)) }
        switch result {
        case "FOUND": return .sent
        case "MISSING": return .missing
        default: return .failed("iTerm2 returned an unexpected prompt response.")
        }
    }

    private func sendToTerminal(_ prompt: String, identity: TerminalIdentity) -> ITermPromptResult {
        guard let tty = identity.tty, let terminalScript else { return .missing }
        let event = appleEvent(handler: "submitPromptTerminal", arguments: [tty, prompt])
        var error: NSDictionary?
        let result = terminalScript.executeAppleEvent(event, error: &error).stringValue
        if let error {
            return .failed(Self.userFacingError(error, terminalName: identity.application.displayName))
        }
        return result == "FOUND" ? .sent : .missing
    }

    private func sendToGhostty(_ prompt: String, identity: TerminalIdentity) -> ITermPromptResult {
        guard let ghosttyScript,
              identity.tty != nil || identity.processID != nil else { return .missing }
        let event = appleEvent(
            handler: "submitPromptGhostty",
            arguments: [identity.tty ?? "", identity.processID.map(String.init) ?? "", prompt]
        )
        var error: NSDictionary?
        let result = ghosttyScript.executeAppleEvent(event, error: &error).stringValue
        if let error {
            return .failed(Self.userFacingError(error, terminalName: identity.application.displayName))
        }
        return result == "FOUND" ? .sent : .missing
    }

    private func sendToWezTerm(_ prompt: String, identity: TerminalIdentity) -> ITermPromptResult {
        guard let pane = identity.weztermPane,
              let socket = identity.weztermUnixSocket,
              !socket.isEmpty else { return .missing }
        let result = runCommand(
            "wezterm",
            arguments: ["cli", "send-text", "--no-paste", "--pane-id", pane, prompt + "\r"],
            environment: ["WEZTERM_UNIX_SOCKET": socket]
        )
        return result.isSuccess ? .sent : .failed(result.message ?? "WezTerm did not accept the prompt.")
    }

    private func sendToKitty(_ prompt: String, identity: TerminalIdentity) -> ITermPromptResult {
        guard let windowID = identity.kittyWindowID,
              let socket = identity.kittyRemoteSocket,
              !socket.isEmpty else { return .missing }
        let result = runCommand(
            "kitten",
            arguments: [
                "@", "--to", socket, "send-text",
                "--match", "id:\(windowID)",
                "--bracketed-paste", "disable",
                prompt + "\r"
            ]
        )
        return result.isSuccess ? .sent : .failed(result.message ?? "kitty did not accept the prompt.")
    }

    private func sendToTmux(_ prompt: String, identity: TerminalIdentity) -> ITermPromptResult {
        guard let pane = identity.tmuxPane,
              let socket = identity.tmuxSocket,
              !socket.isEmpty else { return .missing }
        let text = runCommand("tmux", arguments: ["-S", socket, "send-keys", "-t", pane, "-l", prompt])
        guard text.isSuccess else { return .failed(text.message ?? "tmux did not accept the prompt.") }
        let enter = runCommand("tmux", arguments: ["-S", socket, "send-keys", "-t", pane, "C-m"])
        return enter.isSuccess ? .sent : .failed(enter.message ?? "tmux did not accept Enter.")
    }

    private func sendToZellij(_ prompt: String, identity: TerminalIdentity) -> ITermPromptResult {
        guard let session = identity.zellijSessionName,
              !session.isEmpty,
              let pane = identity.zellijPaneID,
              !pane.isEmpty else { return .missing }
        let text = runCommand(
            "zellij",
            arguments: ["--session", session, "action", "paste", "--pane-id", pane, prompt]
        )
        guard text.isSuccess else {
            return .failed(text.message ?? "Zellij did not accept the prompt.")
        }
        let enter = runCommand(
            "zellij",
            arguments: ["--session", session, "action", "send-keys", "--pane-id", pane, "Enter"]
        )
        return enter.isSuccess ? .sent : .failed(enter.message ?? "Zellij did not accept Enter.")
    }

    private struct CommandResult {
        let isSuccess: Bool
        let message: String?
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
            return CommandResult(isSuccess: process.terminationStatus == 0, message: text.isEmpty ? nil : text)
        } catch {
            return CommandResult(isSuccess: false, message: error.localizedDescription)
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

    private static let terminalPromptSource = """
    on submitPromptTerminal(targetTTY, promptText)
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if (tty of terminalTab as text) is (targetTTY as text) then
                        do script (promptText as text) in terminalTab
                        return "FOUND"
                    end if
                end repeat
            end repeat
        end tell
        return "MISSING"
    end submitPromptTerminal
    """

    private static let ghosttyPromptSource = """
    on submitPromptGhostty(targetTTY, targetPID, promptText)
        tell application "Ghostty"
            repeat with terminalSurface in terminals
                if (targetTTY as text) is not "" and (tty of terminalSurface as text) is (targetTTY as text) then
                    input text (promptText as text) to terminalSurface
                    send key "enter" to terminalSurface
                    return "FOUND"
                end if
                if (targetPID as text) is not "" and (pid of terminalSurface as text) is (targetPID as text) then
                    input text (promptText as text) to terminalSurface
                    send key "enter" to terminalSurface
                    return "FOUND"
                end if
            end repeat
        end tell
        return "MISSING"
    end submitPromptGhostty
    """

    private static func userFacingError(_ error: NSDictionary, terminalName: String = "iTerm2") -> String {
        let number = error[NSAppleScript.errorNumber] as? Int
        switch number {
        case -1743:
            return "Allow Noturcode to control \(terminalName) in Privacy & Security › Automation."
        case -600:
            return "\(terminalName) is not running."
        case -1712:
            return "\(terminalName) did not respond. Try Send again."
        default:
            return error[NSAppleScript.errorMessage] as? String ?? "Could not send to this terminal session."
        }
    }
}
