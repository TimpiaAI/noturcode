import Foundation

public enum ITermPromptScript {
    public static let source = """
    on submitPrompt(targetID, promptText)
        set wantedID to targetID as text
        set outgoingText to promptText as text
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if (unique ID of terminalSession as text) is wantedID then
                            tell terminalSession
                                write text outgoingText newline false
                                write text (ASCII character 13) newline false
                            end tell
                            return "FOUND"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "MISSING"
    end submitPrompt

    on insertWithoutSubmitting(targetID, promptText)
        set wantedID to targetID as text
        set outgoingText to promptText as text
        set pasteStart to (ASCII character 27) & "[200~"
        set pasteEnd to (ASCII character 27) & "[201~"
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if (unique ID of terminalSession as text) is wantedID then
                            tell terminalSession
                                write text (pasteStart & outgoingText & pasteEnd) newline false
                            end tell
                            return "FOUND"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "MISSING"
    end insertWithoutSubmitting
    """
}
