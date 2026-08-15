import Foundation

public enum ITermNavigationScript {
    public static let source = """
    on navigate(targetID, targetTTY)
        set wantedID to targetID as text
        set wantedTTY to targetTTY as text
        if wantedTTY is not "" and wantedTTY does not start with "/dev/" then set wantedTTY to "/dev/" & wantedTTY
        tell application "iTerm2"
            set targetWindowID to missing value
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if (unique ID of terminalSession as text) is wantedID then
                            set targetWindowID to id of terminalWindow
                            exit repeat
                        end if
                    end repeat
                    if targetWindowID is not missing value then exit repeat
                end repeat
                if targetWindowID is not missing value then exit repeat
            end repeat

            -- A pane can keep its TTY while iTerm replaces its UUID. Use the
            -- captured local TTY as the stable fallback and adopt the new UUID.
            if targetWindowID is missing value and wantedTTY is not "" then
                repeat with terminalWindow in windows
                    repeat with terminalTab in tabs of terminalWindow
                        repeat with terminalSession in sessions of terminalTab
                            if (tty of terminalSession as text) is wantedTTY then
                                set wantedID to unique ID of terminalSession as text
                                set targetWindowID to id of terminalWindow
                                exit repeat
                            end if
                        end repeat
                        if targetWindowID is not missing value then exit repeat
                    end repeat
                    if targetWindowID is not missing value then exit repeat
                end repeat
            end if

            if targetWindowID is missing value then return "MISSING"

            -- Window object specifiers are ordered front-to-back. Selecting one
            -- can change those indices, so retain its stable id and reacquire
            -- the hierarchy only after it is frontmost.
            set targetWindow to first window whose id is targetWindowID
            set miniaturized of targetWindow to false
            select targetWindow
            activate
            delay 0.03
            -- Multiple iTerm windows can change front-to-back order during
            -- activation. Reacquire the exact stable window id, never the
            -- implicit current window.
            set targetWindow to first window whose id is targetWindowID

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
