import Foundation

/// Read-only lookup used when iTerm recreates a pane and changes its UUID while
/// the Codex/Claude process keeps the same controlling TTY.
public enum ITermSessionLookupScript {
    public static let source = """
    on sessionIDForTTY(targetTTY)
        set wantedTTY to targetTTY as text
        if wantedTTY does not start with "/dev/" then set wantedTTY to "/dev/" & wantedTTY
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if (tty of terminalSession as text) is wantedTTY then
                            return unique ID of terminalSession as text
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "MISSING"
    end sessionIDForTTY
    """
}
