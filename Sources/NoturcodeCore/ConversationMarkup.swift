import Foundation

public enum ConversationMarkupBlock: Equatable, Sendable {
    case markdown(String)
    case code(language: String?, content: String)
    case table(String)
    case diagram(String)
}

public enum ConversationMarkupParser {
    public static func parse(_ source: String) -> [ConversationMarkupBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [ConversationMarkupBlock] = []
        var markdownLines: [String] = []
        var index = 0

        func trimmedNewlines(_ text: String) -> String {
            text.trimmingCharacters(in: .newlines)
        }

        func flushMarkdown() {
            let text = markdownLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.markdown(text)) }
            markdownLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fence(in: trimmed) {
                flushMarkdown()
                let languageText = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                let language = languageText.isEmpty ? nil : languageText
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(.code(
                    language: language,
                    content: trimmedNewlines(codeLines.joined(separator: "\n"))
                ))
                continue
            }

            if isTableHeader(at: index, lines: lines) {
                flushMarkdown()
                var tableLines: [String] = []
                while index < lines.count, isTableLine(lines[index]) {
                    tableLines.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.table(tableLines.joined(separator: "\n")))
                continue
            }

            if isDiagramAnchor(line) {
                flushMarkdown()
                var diagramLines: [String] = []
                while index < lines.count, isDiagramContinuation(lines[index]) {
                    diagramLines.append(lines[index])
                    index += 1
                }
                blocks.append(.diagram(trimmedNewlines(diagramLines.joined(separator: "\n"))))
                continue
            }

            markdownLines.append(line)
            index += 1
        }

        flushMarkdown()
        return blocks
    }

    private static func fence(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isTableHeader(at index: Int, lines: [String]) -> Bool {
        guard index + 1 < lines.count,
              isTableLine(lines[index]),
              isTableLine(lines[index + 1]) else { return false }
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        return separator.range(
            of: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.contains("|")
    }

    private static let boxCharacters = CharacterSet(charactersIn: "┌┐└┘│─├┤┬┴┼╭╮╯╰═║╔╗╚╝╠╣╦╩╬")
    private static let diagramCharacters = CharacterSet(charactersIn: "┌┐└┘│─├┤┬┴┼╭╮╯╰═║╔╗╚╝╠╣╦╩╬▲▼◀▶→←↑↓↔↕●○◆◇■□")

    private static func isDiagramAnchor(_ line: String) -> Bool {
        line.rangeOfCharacter(from: boxCharacters) != nil
    }

    private static func isDiagramContinuation(_ line: String) -> Bool {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return line.rangeOfCharacter(from: diagramCharacters) != nil
    }
}
