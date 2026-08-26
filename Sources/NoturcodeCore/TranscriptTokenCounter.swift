import Foundation

public enum TranscriptTokenCounter {
    public static func count(source: AgentSource, path: String, fromOffset: UInt64 = 0) -> Int? {
        let expandedPath = (path as NSString).expandingTildeInPath
        if source == .pi || source == .omp {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath), options: [.mappedIfSafe]) else {
                return nil
            }
            return PiFamilyTranscriptParser.parse(data: data, limit: 1).totalTokens
        }
        guard let handle = FileHandle(forReadingAtPath: expandedPath) else { return nil }
        defer { try? handle.close() }

        var claudeMessageIDs = Set<String>()
        var claudeTotal = 0
        var codexTotal: Int?

        do {
            let end = try handle.seekToEnd()
            let start: UInt64
            switch source {
            case .claude:
                start = min(fromOffset, end)
            case .codex:
                start = end > 2_000_000 ? end - 2_000_000 : 0
            case .gemini, .pi, .omp, .hermes, .opencode, .grok, .harness:
                return nil
            }
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }

        func consume(_ data: Data) {
                guard !data.isEmpty,
                      let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
                switch source {
                case .claude:
                    guard value.firstString(for: ["type"]) == "assistant",
                          let usage = value.value(at: ["message", "usage"]) else { return }
                    let messageID = value.firstString(at: [["message", "id"], ["requestId"]])
                        ?? "line-\(claudeMessageIDs.count)"
                    guard claudeMessageIDs.insert(messageID).inserted else { return }
                    claudeTotal += tokenTotal(
                        usage,
                        keys: ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    )
                case .codex:
                    guard value.firstString(for: ["type"]) == "event_msg",
                          value.firstString(at: [["payload", "type"]]) == "token_count" else { return }
                    if let total = value.value(at: ["payload", "info", "total_token_usage", "total_tokens"])?.intValue {
                        codexTotal = total
                    }
                case .gemini, .pi, .omp, .hermes, .opencode, .grok, .harness:
                    return
                }
        }

        do {
            var buffer = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    consume(Data(buffer[..<newline]))
                    buffer.removeSubrange(...newline)
                }
            }
            consume(buffer)
        } catch {
            return nil
        }

        switch source {
        case .claude: return claudeTotal > 0 ? claudeTotal : nil
        case .codex: return codexTotal
        case .gemini, .pi, .omp, .hermes, .opencode, .grok, .harness: return nil
        }
    }

    private static func tokenTotal(_ usage: JSONValue, keys: [String]) -> Int {
        keys.reduce(0) { $0 + (usage[$1]?.intValue ?? 0) }
    }

    public static func fileSize(path: String) -> UInt64? {
        let expandedPath = (path as NSString).expandingTildeInPath
        let attributes = try? FileManager.default.attributesOfItem(atPath: expandedPath)
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }
}
