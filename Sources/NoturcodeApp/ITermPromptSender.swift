import AppKit
import Carbon
import Foundation
import NoturcodeCore

enum ITermPromptResult: Equatable, Sendable {
    case sent
    case missing
    case failed(String)
}

/// Sends user-confirmed text to one exact iTerm2 session. It never activates,
/// selects, moves, resizes, or otherwise changes the user's terminal windows.
@MainActor
final class ITermPromptSender {
    private let compiledScript: NSAppleScript?
    private let compilationError: String?
    private let usesFixture: Bool
    private let resolver = ITermSessionResolver()

    init() {
        usesFixture = CommandLine.arguments.contains("--ui-test-hover-first")
        guard !usesFixture else {
            compiledScript = nil
            compilationError = nil
            return
        }
        guard let script = NSAppleScript(source: ITermPromptScript.source) else {
            compiledScript = nil
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
    }

    func send(_ prompt: String, to target: TerminalTarget, sourceProcessID: Int32? = nil) -> ITermPromptResult {
        if usesFixture { return .sent }
        let first = sendExact(prompt, to: target)
        guard case .missing = first,
              let sourceProcessID,
              let rebound = resolver.resolve(processID: sourceProcessID),
              rebound != target else { return first }
        return sendExact(prompt, to: rebound)
    }

    private func sendExact(_ prompt: String, to target: TerminalTarget) -> ITermPromptResult {
        guard let compiledScript else {
            return .failed(compilationError ?? "Prompt sender is unavailable.")
        }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "submitPrompt"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: target.uniqueID), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: prompt), at: 2)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var error: NSDictionary?
        let result = compiledScript.executeAppleEvent(event, error: &error).stringValue
        if let error {
            return .failed(Self.userFacingError(error))
        }
        switch result {
        case "FOUND": return .sent
        case "MISSING": return .missing
        default: return .failed("iTerm2 returned an unexpected prompt response.")
        }
    }

    private static func userFacingError(_ error: NSDictionary) -> String {
        let number = error[NSAppleScript.errorNumber] as? Int
        switch number {
        case -1743:
            return "Allow iTerm2 access in Privacy & Security › Automation."
        case -600:
            return "iTerm2 is not running."
        case -1712:
            return "iTerm2 did not respond. Try Send again."
        default:
            return error[NSAppleScript.errorMessage] as? String ?? "Could not send to this iTerm2 session."
        }
    }
}
