import AppKit
import Carbon
import Foundation
import NoturcodeCore

enum ITermViewportResult: Equatable, Sendable {
    case found(String)
    case missing
    case failed(String)
}

/// Reads iTerm2's documented, currently visible session text. It never selects
/// a tab, activates iTerm2, writes input, scrolls, resizes, or moves a window.
@MainActor
final class ITermViewportReader {
    private let compiledScript: NSAppleScript?
    private let compilationError: String?
    private let usesFixture: Bool

    init() {
        usesFixture = CommandLine.arguments.contains("--ui-test-hover-first")
        guard !usesFixture else {
            compiledScript = nil
            compilationError = nil
            return
        }
        guard let script = NSAppleScript(source: ITermViewportScript.source) else {
            compiledScript = nil
            compilationError = "Viewport reader could not be prepared."
            return
        }
        var error: NSDictionary?
        if script.compileAndReturnError(&error) {
            compiledScript = script
            compilationError = nil
        } else {
            compiledScript = nil
            compilationError = error?[NSAppleScript.errorMessage] as? String
                ?? "Viewport reader could not be compiled."
        }
    }

    func snapshot(_ target: TerminalTarget) -> ITermViewportResult {
        if usesFixture {
            return .found("Check the exact notch composition.\n\n› Read SessionViews.swift\n› Build FluidMarble.metal\n› Run UI verification\n\nWorking · waiting for the next tool call")
        }
        guard let compiledScript else {
            return .failed(compilationError ?? "Viewport reader is unavailable.")
        }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "viewport"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: target.uniqueID), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var error: NSDictionary?
        let result = compiledScript.executeAppleEvent(event, error: &error).stringValue
        if let error {
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "Could not read the visible terminal viewport.")
        }
        guard let result else { return .failed("iTerm2 returned no visible terminal text.") }
        if result == "MISSING" { return .missing }
        guard result.hasPrefix("FOUND\n") else { return .failed("iTerm2 returned an unexpected viewport response.") }
        return .found(String(result.dropFirst(6)).terminalViewportSanitized)
    }
}

private extension String {
    var terminalViewportSanitized: String {
        let scalars = unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
