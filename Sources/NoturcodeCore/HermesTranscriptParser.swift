import Foundation

public enum HermesTranscriptParser {
    public static func parse(databaseRows data: Data, limit: Int = 80) -> [ChatTranscriptEntry] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var entries: [ChatTranscriptEntry] = []
        var toolIndexes: [String: Int] = [:]

        for row in rows {
            let messageID = string(row["message_id"]) ?? "row-\(entries.count)"
            let role = (string(row["role"]) ?? "assistant").lowercased()
            let content = (string(row["content"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let timestamp = secondsDate(row["timestamp"])
            let model = qualifiedModel(
                provider: string(row["provider"]),
                model: string(row["model"])
            )

            if role == "tool" {
                let callID = string(row["tool_call_id"]) ?? "tool-\(messageID)"
                if let index = toolIndexes[callID] {
                    if !content.isEmpty { entries[index].detail = content }
                    if let name = string(row["tool_name"]), !name.isEmpty {
                        entries[index].title = displayToolName(name)
                    }
                } else {
                    entries.append(ChatTranscriptEntry(
                        id: "hermes-tool-\(callID)",
                        kind: .tool,
                        title: displayToolName(string(row["tool_name"]) ?? "Tool"),
                        text: "",
                        detail: content.isEmpty ? nil : content,
                        timestamp: timestamp,
                        model: model
                    ))
                    toolIndexes[callID] = entries.count - 1
                }
                continue
            }

            if !content.isEmpty {
                let kind: ChatTranscriptKind = switch role {
                case "user": .user
                case "system", "developer": .system
                default: .assistant
                }
                entries.append(ChatTranscriptEntry(
                    id: "hermes-\(messageID)",
                    kind: kind,
                    text: content,
                    timestamp: timestamp,
                    model: model
                ))
            }

            guard role == "assistant" else { continue }
            for (index, call) in toolCalls(row["tool_calls"]).enumerated() {
                let function = call["function"] as? [String: Any]
                let callID = string(call["id"])
                    ?? string(call["call_id"])
                    ?? "\(messageID)-\(index)"
                let name = string(function?["name"] ?? call["name"]) ?? "Tool"
                let arguments = prettyJSON(function?["arguments"] ?? call["arguments"])
                entries.append(ChatTranscriptEntry(
                    id: "hermes-tool-\(callID)",
                    kind: .tool,
                    title: displayToolName(name),
                    text: arguments,
                    timestamp: timestamp,
                    model: model
                ))
                toolIndexes[callID] = entries.count - 1
            }
        }

        let boundedLimit = max(1, limit)
        guard entries.count > boundedLimit else { return entries }
        let recentIDs = Set(entries.suffix(boundedLimit).map(\.id))
        let conversationIDs = Set(entries.filter {
            $0.kind == .user || $0.kind == .assistant
        }.suffix(20).map(\.id))
        return entries.filter { recentIDs.contains($0.id) || conversationIDs.contains($0.id) }
    }

    private static func toolCalls(_ value: Any?) -> [[String: Any]] {
        if let calls = value as? [[String: Any]] { return calls }
        guard let text = value as? String,
              let data = text.data(using: .utf8),
              let calls = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return calls
    }

    private static func prettyJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        let object: Any
        if let text = value as? String {
            guard let data = text.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) else {
                return text
            }
            object = decoded
        } else {
            object = value
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ) else { return String(describing: object) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func displayToolName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func qualifiedModel(provider: String?, model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        guard let provider, !provider.isEmpty, !model.hasPrefix(provider + "/") else {
            return model
        }
        return "\(provider)/\(model)"
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func secondsDate(_ value: Any?) -> Date? {
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        if let value = value as? String, let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
