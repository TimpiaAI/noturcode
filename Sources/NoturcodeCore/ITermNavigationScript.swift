import Foundation

public enum ITermNavigationScript {
    public static let source = """
    on navigate(targetID)
        set wantedID to targetID as text
        tell application "iTerm2"
            set targetWindowID to missing value
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if (unique ID of terminalSession as text) is wantedID then
                            set targetWindowID to id of terminalWindow
                        end if
                    end repeat
                end repeat
            end repeat

            if targetWindowID is missing value then return "MISSING"

            -- Window object specifiers are ordered front-to-back. Selecting one
            -- can change those indices, so retain its stable id and reacquire
            -- the hierarchy only after it is frontmost.
            set targetWindow to first window whose id is targetWindowID
            set miniaturized of targetWindow to false
            select targetWindow
            activate
            delay 0.03
            set targetWindow to current window

            repeat with terminalTab in tabs of targetWindow
                repeat with terminalSession in sessions of terminalTab
                    if (unique ID of terminalSession as text) is wantedID then
                        select terminalTab
                        select terminalSession
                        delay 0.03
                        if (unique ID of current session of terminalTab as text) is wantedID then
                            return "FOUND"
                        end if
                        return "MISMATCH"
                    end if
                end repeat
            end repeat

            return "MISMATCH"
        end tell
    end navigate
    """
}
