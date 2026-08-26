import Foundation

public enum ChatTranscriptKind: String, Equatable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public struct ChatTranscriptEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: ChatTranscriptKind
    public var title: String?
    public var text: String
    public var detail: String?
    public var timestamp: Date?
    public var imagePaths: [String]
    public var model: String?

    public init(
        id: String,
        kind: ChatTranscriptKind,
        title: String? = nil,
        text: String,
        detail: String? = nil,
        timestamp: Date? = nil,
        imagePaths: [String] = [],
        model: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.detail = detail
        self.timestamp = timestamp
        self.imagePaths = imagePaths
        self.model = model
    }
}

public enum AgentTranscriptParser {
    public static func parse(data: Data, source: AgentSource, limit: Int = 80) -> [ChatTranscriptEntry] {
        if source == .pi || source == .omp {
            return PiFamilyTranscriptParser.parse(data: data, limit: limit).entries
        }
        let text = String(decoding: data, as: UTF8.self)
        var entries: [ChatTranscriptEntry] = []
        var toolIndexes: [String: Int] = [:]
        var codexModel: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineText = String(line)
            guard let lineData = lineText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            let recordID = stableRecordID(object: object, line: lineText)
            if object["type"] as? String == "noturcode_native" {
                parseNative(object, recordID: recordID, entries: &entries)
                continue
            }
            switch source {
            case .claude:
                parseClaude(object, recordID: recordID, entries: &entries, toolIndexes: &toolIndexes)
            case .codex:
                parseCodex(
                    object,
                    recordID: recordID,
                    currentModel: &codexModel,
                    entries: &entries,
                    toolIndexes: &toolIndexes
                )
            case .gemini, .pi, .omp, .hermes, .opencode, .grok, .harness:
                break
            }
        }
        let boundedLimit = max(1, limit)
        guard entries.count > boundedLimit else { return entries }
        let recentIDs = Set(entries.suffix(boundedLimit).map(\.id))
        let conversationIDs = Set(entries.filter { $0.kind == .user || $0.kind == .assistant }.suffix(20).map(\.id))
        return entries.filter { recentIDs.contains($0.id) || conversationIDs.contains($0.id) }
    }

    private static func parseNative(
        _ object: [String: Any],
        recordID: String,
        entries: inout [ChatTranscriptEntry]
    ) {
        guard let rawKind = object["kind"] as? String,
              let kind = ChatTranscriptKind(rawValue: rawKind),
              let text = object["text"] as? String else { return }
        let entry = ChatTranscriptEntry(
            id: object["id"] as? String ?? recordID,
            kind: kind,
            title: object["title"] as? String,
            text: text,
            detail: object["detail"] as? String,
            timestamp: date(object["timestamp"]),
            imagePaths: object["imagePaths"] as? [String] ?? imagePaths(in: text),
            model: object["model"] as? String
        )
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private static func parseClaude(
        _ object: [String: Any],
        recordID: String,
        entries: inout [ChatTranscriptEntry],
        toolIndexes: inout [String: Int]
    ) {
        guard let type = object["type"] as? String,
              let message = object["message"] as? [String: Any] else { return }
        let timestamp = date(object["timestamp"])
        let content = message["content"]
        let model = message["model"] as? String

        if type == "user" {
            if let string = content as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendMessage(.user, text: string, id: "claude-\(recordID)-user", timestamp: timestamp, model: nil, to: &entries)
                return
            }
            guard let blocks = content as? [[String: Any]] else { return }
            var userText: [String] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { userText.append(text) }
                case "tool_result":
                    guard let toolID = block["tool_use_id"] as? String,
                          let index = toolIndexes[toolID] else { continue }
                    let result = contentText(block["content"])
                    if !result.isEmpty { entries[index].detail = result }
                default:
                    break
                }
            }
            if !userText.isEmpty {
                appendMessage(.user, text: userText.joined(separator: "\n"), id: "claude-\(recordID)-user", timestamp: timestamp, model: nil, to: &entries)
            }
            return
        }

        guard type == "assistant" else { return }
        if let string = content as? String,
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendMessage(.assistant, text: string, id: "claude-\(recordID)-assistant", timestamp: timestamp, model: model, to: &entries)
            return
        }
        guard let blocks = content as? [[String: Any]] else { return }
        for (blockIndex, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.isEmpty else { continue }
                appendMessage(.assistant, text: text, id: "claude-\(recordID)-\(blockIndex)", timestamp: timestamp, model: model, to: &entries)
            case "tool_use":
                let toolID = block["id"] as? String ?? "claude-\(recordID)-\(blockIndex)"
                let name = block["name"] as? String ?? "Tool"
                let input = prettyJSON(block["input"]) ?? ""
                entries.append(ChatTranscriptEntry(
                    id: toolID,
                    kind: .tool,
                    title: humanized(name),
                    text: input,
                    timestamp: timestamp,
                    imagePaths: imagePaths(in: input),
                    model: model
                ))
                toolIndexes[toolID] = entries.count - 1
            default:
                break
            }
        }
    }

    private static func parseCodex(
        _ object: [String: Any],
        recordID: String,
        currentModel: inout String?,
        entries: inout [ChatTranscriptEntry],
        toolIndexes: inout [String: Int]
    ) {
        if object["type"] as? String == "turn_context",
           let payload = object["payload"] as? [String: Any],
           let model = payload["model"] as? String {
            currentModel = model
            return
        }
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return }
        let timestamp = date(object["timestamp"])

        switch type {
        case "message":
            let role = payload["role"] as? String
            guard role == "user" || role == "assistant" else { return }
            let text = contentText(payload["content"])
            guard !text.isEmpty else { return }
            appendMessage(
                role == "user" ? .user : .assistant,
                text: text,
                id: "codex-\(recordID)-message",
                timestamp: timestamp,
                model: role == "assistant" ? currentModel : nil,
                to: &entries
            )
        case "function_call", "custom_tool_call":
            let callID = payload["call_id"] as? String ?? payload["id"] as? String ?? "codex-\(recordID)-tool"
            let name = payload["name"] as? String ?? "Tool"
            let input = prettyJSON(payload["arguments"] ?? payload["input"]) ?? ""
            entries.append(ChatTranscriptEntry(
                id: callID,
                kind: .tool,
                title: semanticToolTitle(name: name, input: input),
                text: input,
                timestamp: timestamp,
                imagePaths: imagePaths(in: input),
                model: currentModel
            ))
            toolIndexes[callID] = entries.count - 1
        case "function_call_output", "custom_tool_call_output":
            guard let callID = payload["call_id"] as? String,
                  let index = toolIndexes[callID] else { return }
            let output = contentText(payload["output"] ?? payload["content"])
            if !output.isEmpty { entries[index].detail = output }
        default:
            break
        }
    }

    /// JSONL windows can discard old lines as they grow. IDs derived from a
    /// line's array index therefore make every surviving SwiftUI row look new.
    /// Prefer provider IDs, then use a deterministic hash of the record itself.
    private static func stableRecordID(object: [String: Any], line: String) -> String {
        if let uuid = object["uuid"] as? String, !uuid.isEmpty { return uuid }
        if let payload = object["payload"] as? [String: Any] {
            if let id = payload["id"] as? String, !id.isEmpty { return id }
            if let callID = payload["call_id"] as? String, !callID.isEmpty { return callID }
        }
        if let message = object["message"] as? [String: Any],
           let id = message["id"] as? String, !id.isEmpty { return id }
        if let ordinal = object["ordinal"] as? Int { return "ordinal-\(ordinal)" }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in line.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func appendMessage(
        _ kind: ChatTranscriptKind,
        text: String,
        id: String,
        timestamp: Date?,
        model: String?,
        to entries: inout [ChatTranscriptEntry]
    ) {
        entries.append(ChatTranscriptEntry(
            id: id,
            kind: kind,
            text: text,
            timestamp: timestamp,
            imagePaths: imagePaths(in: text),
            model: model
        ))
    }

    private static func contentText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let blocks = value as? [[String: Any]] else {
            return prettyJSON(value) ?? ""
        }
        return blocks.compactMap { block in
            block["text"] as? String ?? block["content"] as? String
        }.joined(separator: "\n")
    }

    private static func prettyJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            guard let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
                return string
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func humanized(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "functions.", with: "")
            .replacingOccurrences(of: "mcp__", with: "")
    }

    private static func semanticToolTitle(name: String, input: String) -> String {
        let value = "\(name) \(input)".lowercased()
        let mappings: [(needles: [String], title: String)] = [
            (["apply_patch", "apply patch"], "Edit files"),
            (["view_image", "view image"], "Inspect image"),
            (["imagegen", "image_gen"], "Generate image"),
            (["write_stdin", "write stdin"], "Continue command"),
            (["exec_command", "exec command"], "Run command"),
            (["web__run", "search_query", "image_query"], "Search web"),
            (["spawn_agent", "spawn agent"], "Start agent"),
            (["send_message", "followup_task", "send message"], "Message agent"),
            (["wait_agent", "wait agent"], "Wait for agents"),
            (["update_plan", "update plan"], "Update plan"),
            (["request_user_input"], "Ask user"),
            (["read_mcp_resource"], "Read resource")
        ]
        if let mapping = mappings.first(where: { item in item.needles.contains(where: value.contains) }) {
            return mapping.title
        }
        switch name.lowercased() {
        case "exec": return "Run tool"
        case "exec_command": return "Run command"
        case "apply_patch": return "Edit files"
        default:
            let readable = humanized(name)
            return readable.prefix(1).uppercased() + readable.dropFirst()
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func imagePaths(in text: String) -> [String] {
        let pattern = #"(/[^"]+?\.(?:png|jpe?g|gif|webp|heic|tiff?))(?=["\s\n]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let paths: [String] = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        }
        return paths.reduce(into: [String]()) { result, path in
            if !result.contains(path) { result.append(path) }
        }
    }
}
