import Foundation

public struct PiFamilyTranscriptSnapshot: Equatable, Sendable {
    public var entries: [ChatTranscriptEntry]
    public var sessionName: String?
    public var provider: String?
    public var model: String?
    public var agentRole: String?
    public var totalTokens: Int?
    public var turnState: TranscriptTurnState

    public init(
        entries: [ChatTranscriptEntry],
        sessionName: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        agentRole: String? = nil,
        totalTokens: Int? = nil,
        turnState: TranscriptTurnState = .active
    ) {
        self.entries = entries
        self.sessionName = sessionName
        self.provider = provider
        self.model = model
        self.agentRole = agentRole
        self.totalTokens = totalTokens
        self.turnState = turnState
    }
}

/// Parses the tree JSONL used by Pi and OMP. Harness identity is supplied by
/// the caller. Provider and model identity come from the transcript itself.
public enum PiFamilyTranscriptParser {
    public static func parse(
        data: Data,
        limit: Int = 80,
        after lastPromptAt: Date? = nil
    ) -> PiFamilyTranscriptSnapshot {
        let objects = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap(jsonObject)
        guard !objects.isEmpty else { return PiFamilyTranscriptSnapshot(entries: []) }

        let path = activePath(in: objects)
        var entries: [ChatTranscriptEntry] = []
        var toolIndexes: [String: Int] = [:]
        var sessionName = normalized(objects.first(where: { ($0["type"] as? String) == "title" })?["title"])
        var provider: String?
        var model: String?
        var agentRole: String?
        var totalTokens = 0
        var turnState: TranscriptTurnState = .active

        if sessionName == nil,
           let header = objects.first(where: { ($0["type"] as? String) == "session" }) {
            sessionName = normalized(header["title"])
        }

        for object in path {
            let type = object["type"] as? String ?? ""
            let recordID = object["id"] as? String ?? stableID(object)
            let entryTimestamp = date(object["timestamp"])

            switch type {
            case "model_change":
                let role = (object["role"] as? String) ?? "default"
                guard role == "default" else { continue }
                if let value = normalized(object["model"]) {
                    let pair = splitModel(value)
                    provider = pair.provider ?? provider
                    model = pair.model
                } else if let modelID = normalized(object["modelId"]) {
                    provider = normalized(object["provider"]) ?? provider
                    model = modelID
                }

            case "session_init":
                agentRole = normalized(object["agent"])
                    ?? normalized(object["modelRole"])
                    ?? agentRole

            case "title_change":
                sessionName = normalized(object["title"]) ?? sessionName

            case "reset_boundary":
                entries.removeAll(keepingCapacity: true)
                toolIndexes.removeAll(keepingCapacity: true)

            case "message":
                guard let message = object["message"] as? [String: Any] else { continue }
                let timestamp = date(message["timestamp"]) ?? entryTimestamp
                let role = message["role"] as? String ?? ""
                if role == "assistant" {
                    let messageProvider = normalized(message["provider"])
                    let messageModel = normalized(message["model"])
                    provider = messageProvider ?? provider
                    model = messageModel ?? model
                    totalTokens += tokenTotal(message["usage"])
                }
                parseMessage(
                    message,
                    recordID: recordID,
                    timestamp: timestamp,
                    fallbackModel: model,
                    entries: &entries,
                    toolIndexes: &toolIndexes
                )
                if lastPromptAt.map({ boundary in timestamp.map { $0 >= boundary } ?? false }) != false {
                    turnState = state(after: message)
                }

            case "custom_message":
                guard object["display"] as? Bool != false else { continue }
                let text = contentText(object["content"])
                if !text.isEmpty {
                    entries.append(ChatTranscriptEntry(
                        id: "pi-custom-\(recordID)",
                        kind: .system,
                        text: text,
                        timestamp: entryTimestamp
                    ))
                }

            case "compaction":
                if let summary = normalized(object["summary"]) {
                    entries.append(ChatTranscriptEntry(
                        id: "pi-compaction-\(recordID)",
                        kind: .system,
                        title: "Context compacted",
                        text: summary,
                        timestamp: entryTimestamp
                    ))
                }

            case "branch_summary":
                if let summary = normalized(object["summary"]) {
                    entries.append(ChatTranscriptEntry(
                        id: "pi-branch-\(recordID)",
                        kind: .system,
                        title: "Branch summary",
                        text: summary,
                        timestamp: entryTimestamp
                    ))
                }

            case "custom":
                if object["customType"] as? String == "session_exit",
                   isAfter(entryTimestamp, lastPromptAt) {
                    turnState = .interrupted
                }

            default:
                continue
            }
        }

        return PiFamilyTranscriptSnapshot(
            entries: bounded(entries, limit: limit),
            sessionName: sessionName,
            provider: provider,
            model: model,
            agentRole: agentRole,
            totalTokens: totalTokens > 0 ? totalTokens : nil,
            turnState: turnState
        )
    }

    private static func activePath(in objects: [[String: Any]]) -> [[String: Any]] {
        let entries = objects.filter {
            $0["id"] is String && ($0["type"] as? String) != "session"
                && ($0["type"] as? String) != "title"
        }
        guard var current = entries.last,
              var currentID = current["id"] as? String else { return [] }
        var byID: [String: [String: Any]] = [:]
        for object in entries {
            if let id = object["id"] as? String { byID[id] = object }
        }
        var reversed: [[String: Any]] = []
        var visited = Set<String>()
        while visited.insert(currentID).inserted {
            reversed.append(current)
            guard let parentID = current["parentId"] as? String,
                  let parent = byID[parentID] else { break }
            current = parent
            currentID = parentID
        }
        return reversed.reversed()
    }

    private static func parseMessage(
        _ message: [String: Any],
        recordID: String,
        timestamp: Date?,
        fallbackModel: String?,
        entries: inout [ChatTranscriptEntry],
        toolIndexes: inout [String: Int]
    ) {
        let role = message["role"] as? String ?? ""
        let messageModel = normalized(message["model"]) ?? fallbackModel
        switch role {
        case "user":
            appendTextMessage(
                kind: .user,
                content: message["content"],
                id: "pi-\(recordID)-user",
                timestamp: timestamp,
                model: nil,
                entries: &entries
            )

        case "assistant":
            if let text = message["content"] as? String {
                appendTextMessage(
                    kind: .assistant,
                    content: text,
                    id: "pi-\(recordID)-assistant",
                    timestamp: timestamp,
                    model: messageModel,
                    entries: &entries
                )
                return
            }
            guard let blocks = message["content"] as? [[String: Any]] else { return }
            for (index, block) in blocks.enumerated() {
                switch block["type"] as? String {
                case "text":
                    guard let text = normalized(block["text"]) else { continue }
                    entries.append(ChatTranscriptEntry(
                        id: "pi-\(recordID)-text-\(index)",
                        kind: .assistant,
                        text: text,
                        timestamp: timestamp,
                        imagePaths: imagePaths(in: text),
                        model: messageModel
                    ))
                case "toolCall", "tool_call", "tool_use":
                    let toolID = normalized(block["id"])
                        ?? normalized(block["toolCallId"])
                        ?? "pi-\(recordID)-tool-\(index)"
                    let name = normalized(block["name"]) ?? normalized(block["toolName"]) ?? "Tool"
                    let input = prettyJSON(block["arguments"] ?? block["input"]) ?? ""
                    entries.append(ChatTranscriptEntry(
                        id: toolID,
                        kind: .tool,
                        title: humanized(name),
                        text: input,
                        timestamp: timestamp,
                        imagePaths: imagePaths(in: input),
                        model: messageModel
                    ))
                    toolIndexes[toolID] = entries.count - 1
                default:
                    continue
                }
            }

        case "toolResult":
            let toolID = normalized(message["toolCallId"]) ?? normalized(message["tool_use_id"])
            let result = contentText(message["content"])
            if let toolID, let index = toolIndexes[toolID] {
                if !result.isEmpty { entries[index].detail = result }
            } else if !result.isEmpty {
                let name = normalized(message["toolName"]) ?? "Tool"
                entries.append(ChatTranscriptEntry(
                    id: toolID ?? "pi-\(recordID)-result",
                    kind: .tool,
                    title: humanized(name),
                    text: "",
                    detail: result,
                    timestamp: timestamp,
                    model: fallbackModel
                ))
            }

        case "bashExecution":
            let command = normalized(message["command"]) ?? ""
            let output = normalized(message["output"])
            entries.append(ChatTranscriptEntry(
                id: "pi-\(recordID)-bash",
                kind: .tool,
                title: "Bash",
                text: command,
                detail: output,
                timestamp: timestamp,
                model: fallbackModel
            ))

        case "custom", "branchSummary", "compactionSummary":
            guard message["display"] as? Bool != false else { return }
            let text = normalized(message["summary"]) ?? contentText(message["content"])
            if !text.isEmpty {
                entries.append(ChatTranscriptEntry(
                    id: "pi-\(recordID)-system",
                    kind: .system,
                    text: text,
                    timestamp: timestamp
                ))
            }

        default:
            return
        }
    }

    private static func appendTextMessage(
        kind: ChatTranscriptKind,
        content: Any?,
        id: String,
        timestamp: Date?,
        model: String?,
        entries: inout [ChatTranscriptEntry]
    ) {
        let text = contentText(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.append(ChatTranscriptEntry(
            id: id,
            kind: kind,
            text: text,
            timestamp: timestamp,
            imagePaths: imagePaths(in: text),
            model: model
        ))
    }

    private static func state(after message: [String: Any]) -> TranscriptTurnState {
        switch message["role"] as? String {
        case "assistant":
            switch message["stopReason"] as? String {
            case "stop", "length": return .completed
            case "aborted", "error": return .interrupted
            default: return .active
            }
        case "user", "toolResult":
            return .active
        default:
            return .active
        }
    }

    private static func tokenTotal(_ value: Any?) -> Int {
        guard let usage = value as? [String: Any] else { return 0 }
        if let total = integer(usage["totalTokens"]), total > 0 { return total }
        return ["input", "output", "cacheRead", "cacheWrite"]
            .compactMap { integer(usage[$0]) }
            .reduce(0, +)
    }

    private static func splitModel(_ value: String) -> (provider: String?, model: String) {
        guard let separator = value.firstIndex(of: "/") else { return (nil, value) }
        let provider = String(value[..<separator])
        let model = String(value[value.index(after: separator)...])
        return (provider.isEmpty ? nil : provider, model.isEmpty ? value : model)
    }

    private static func bounded(_ entries: [ChatTranscriptEntry], limit: Int) -> [ChatTranscriptEntry] {
        let boundedLimit = max(1, limit)
        guard entries.count > boundedLimit else { return entries }
        let recentIDs = Set(entries.suffix(boundedLimit).map(\.id))
        let conversationIDs = Set(entries
            .filter { $0.kind == .user || $0.kind == .assistant }
            .suffix(20)
            .map(\.id))
        return entries.filter { recentIDs.contains($0.id) || conversationIDs.contains($0.id) }
    }

    private static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func normalized(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func contentText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text": return block["text"] as? String
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func prettyJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func humanized(_ value: String) -> String {
        let words = value
            .replacingOccurrences(of: "functions:", with: "")
            .replacingOccurrences(of: "functions.", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func isAfter(_ timestamp: Date?, _ boundary: Date?) -> Bool {
        guard let boundary else { return true }
        return timestamp.map { $0 >= boundary } ?? false
    }

    private static func imagePaths(in text: String) -> [String] {
        let pattern = #"(/[^\"]+?\.(?:png|jpe?g|gif|webp|heic|tiff?))(?=[\"\s\n]|$)"#
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

    private static func stableID(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
