import AppKit
import Carbon
import Foundation
import NoturcodeCore

enum ITermRevealResult: Equatable, Sendable {
    case revealed(elapsed: TimeInterval)
    case missing
    case failed(String)
}

@MainActor
final class ITermNavigator {
    private let compiledScript: NSAppleScript?
    private let compilationError: String?

    init() {
        guard let script = NSAppleScript(source: ITermNavigationScript.source) else {
            compiledScript = nil
            compilationError = "Noturcode could not prepare iTerm2 navigation."
            return
        }
        var error: NSDictionary?
        if script.compileAndReturnError(&error) {
            compiledScript = script
            compilationError = nil
        } else {
            compiledScript = nil
            compilationError = error?[NSAppleScript.errorMessage] as? String
                ?? "Noturcode could not compile iTerm2 navigation."
        }
    }

    func reveal(_ target: TerminalTarget) -> ITermRevealResult {
        let started = Date()
        guard let compiledScript else {
            return .failed(compilationError ?? "Noturcode could not prepare iTerm2 navigation.")
        }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: "navigate"),
            forKeyword: AEKeyword(keyASSubroutineName)
        )
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: target.uniqueID), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var error: NSDictionary?
        let result = compiledScript.executeAppleEvent(event, error: &error).stringValue
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
            return .failed(message ?? "iTerm2 session navigation failed.")
        }
        switch result {
        case "FOUND":
            return .revealed(elapsed: Date().timeIntervalSince(started))
        case "MISSING":
            return .missing
        default:
            return .failed("iTerm2 did not focus the requested split.")
        }
    }
}
