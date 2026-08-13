import AppKit
import Carbon
import Foundation
import NoturcodeCore

/// Rebinds a live agent process to its current iTerm pane without selecting,
/// activating, writing to, moving, or closing any terminal session.
@MainActor
final class ITermSessionResolver {
    private let compiledScript: NSAppleScript?

    init() {
        guard let script = NSAppleScript(source: ITermSessionLookupScript.source) else {
            compiledScript = nil
            return
        }
        var error: NSDictionary?
        compiledScript = script.compileAndReturnError(&error) ? script : nil
    }

    func resolve(processID: Int32) -> TerminalTarget? {
        guard let tty = ProcessAncestry.terminalTTY(pid: processID),
              let compiledScript else { return nil }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "sessionIDForTTY"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: tty), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        guard let identifier = compiledScript.executeAppleEvent(event, error: &error).stringValue,
              error == nil, identifier != "MISSING", !identifier.isEmpty else { return nil }
        return TerminalTarget(sessionID: identifier)
    }
}
