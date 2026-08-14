import Foundation

public enum NoturcodeSummaryContract {
    public static let instruction = """
    Before the final summary, add a compact diagram introduced by the exact line `Noturcode completion map`, followed by a fenced `text` block.
    The diagram must use ASCII boxes, branches, and arrows to show the real flow from request through changed components to verification.
    Make the diagram detailed enough to replace a tool log. Use 8 to 16 lines when the work has multiple parts.
    For each useful branch, name the changed file or component, the concrete change, and the exact verification result.
    Keep it concrete, readable, and at most 16 lines. Use ASCII characters only, such as + - | > < / \\; do not use Mermaid or Unicode box drawing.
    Then end the final response with exactly these three lines:
    Noturcode summary
    Done: [x] <completed work> -> [x] <verification>
    Needs you: <the exact remaining input or action, or Nothing>
    Keep each summary line under 160 characters. Do not use Unicode arrows or Markdown bullets in the three-line summary.
    """

    public static func isCompliant(_ message: String?) -> Bool {
        guard isDisplayable(message), let message, completionMap(in: message) != nil else { return false }
        let doneLine = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { $0.hasPrefix("done:") }
        return doneLine?.hasPrefix("done: [x] ") == true
            && doneLine?.contains(" -> [x] ") == true
    }

    public static func completionMap(in message: String?) -> String? {
        guard let message,
              let marker = message.range(of: "Noturcode completion map", options: [.caseInsensitive]) else {
            return nil
        }
        let remainder = String(message[marker.upperBound...])
        for block in ConversationMarkupParser.parse(remainder) {
            switch block {
            case let .code(language, content):
                let normalizedLanguage = language?.lowercased() ?? ""
                guard normalizedLanguage.isEmpty || normalizedLanguage == "text" || normalizedLanguage == "ascii" else {
                    continue
                }
                let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            case let .diagram(content):
                let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            default:
                continue
            }
        }
        return nil
    }

    /// Older natural-language summaries remain readable in the UI even though
    /// new hook completions must use the stricter ASCII Done flow.
    public static func isDisplayable(_ message: String?) -> Bool {
        guard let message else { return false }
        let normalized = message.lowercased()
        return normalized.contains("noturcode summary")
            && normalized.contains("done:")
            && normalized.contains("needs you:")
    }

    /// Native harness commands must reach Claude Code/Codex unchanged. Adding
    /// model context to `/compact`, `/model`, and similar commands can make the
    /// harness treat them as prompts and defeat context recovery.
    public static func shouldInject(for prompt: String?) -> Bool {
        guard let prompt else { return true }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }
}
