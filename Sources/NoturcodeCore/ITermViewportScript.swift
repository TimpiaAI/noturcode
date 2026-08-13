import Foundation

public enum ITermViewportScript {
    public static let source = """
    on viewport(targetID)
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if (unique ID of terminalSession as text) is targetID then
                            return "FOUND" & linefeed & (text of terminalSession as text)
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "MISSING"
    end viewport
    """
}
