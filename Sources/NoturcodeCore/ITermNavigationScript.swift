import Foundation

public enum ITermNavigationScript {
    public static let source = """
    on navigate(targetID)
        set wantedID to targetID as text
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if (unique ID of terminalSession as text) is wantedID then
                            set miniaturized of terminalWindow to false
                            select terminalTab
                            select terminalSession
                            activate
                            delay 0.03
                            if (unique ID of current session of terminalTab as text) is wantedID then
                                return "FOUND"
                            end if
                            return "MISMATCH"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "MISSING"
    end navigate
    """
}
