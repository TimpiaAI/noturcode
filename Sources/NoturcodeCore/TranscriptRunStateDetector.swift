import Foundation

public struct TranscriptFileRevision: Equatable, Sendable {
    public let size: UInt64
    public let modificationTime: Date

    public init(size: UInt64, modificationTime: Date) {
        self.size = size
        self.modificationTime = modificationTime
    }
}

public enum TranscriptTurnState: Equatable, Sendable {
    case active
    case completed
    case interrupted
}

public enum TranscriptRunStateDetector {
    public static func revision(atPath path: String) -> TranscriptFileRevision? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let modificationTime = attributes[.modificationDate] as? Date,
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return TranscriptFileRevision(
            size: size.uint64Value,
            modificationTime: modificationTime
        )
    }

    public static func turnCompleted(
        atPath path: String,
        source: AgentSource,
        after lastPromptAt: Date,
        maximumBytes: Int = 256 * 1_024
    ) -> Bool {
        turnState(atPath: path, source: source, after: lastPromptAt, maximumBytes: maximumBytes) == .completed
    }

    public static func turnCompleted(data: Data, source: AgentSource, after lastPromptAt: Date) -> Bool {
        turnState(data: data, source: source, after: lastPromptAt) == .completed
    }

    public static func turnState(
        atPath path: String,
        source: AgentSource,
        after lastPromptAt: Date,
        maximumBytes: Int = 256 * 1_024
    ) -> TranscriptTurnState {
        guard source == .claude || source == .codex || source == .pi || source == .omp,
              let data = tailData(atPath: path, maximumBytes: maximumBytes) else { return .active }
        return turnState(data: data, source: source, after: lastPromptAt)
    }

    public static func turnState(
        data: Data,
        source: AgentSource,
        after lastPromptAt: Date
    ) -> TranscriptTurnState {
        let fractionalTimestampFormatter = ISO8601DateFormatter()
        fractionalTimestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeTimestampFormatter = ISO8601DateFormatter()

        switch source {
        case .claude:
            return claudeTurnState(
                data: data,
                after: lastPromptAt,
                fractional: fractionalTimestampFormatter,
                whole: wholeTimestampFormatter
            )
        case .codex:
            return codexTurnState(
                data: data,
                after: lastPromptAt,
                fractional: fractionalTimestampFormatter,
                whole: wholeTimestampFormatter
            )
        case .pi, .omp:
            return PiFamilyTranscriptParser.parse(
                data: data,
                limit: 1,
                after: lastPromptAt
            ).turnState
        default:
            return .active
        }
    }

    private static func claudeTurnState(
        data: Data,
        after lastPromptAt: Date,
        fractional: ISO8601DateFormatter,
        whole: ISO8601DateFormatter
    ) -> TranscriptTurnState {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  let timestamp = timestamp(
                    object["timestamp"],
                    fractional: fractional,
                    whole: whole
                  ) else { continue }

            guard timestamp >= lastPromptAt else { return .active }

            if type == "user" {
                return .active
            }
            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let stopReason = message["stop_reason"] as? String else { continue }
            return stopReason == "end_turn" ? .completed : .active
        }
        return .active
    }

    private static func codexTurnState(
        data: Data,
        after lastPromptAt: Date,
        fractional: ISO8601DateFormatter,
        whole: ISO8601DateFormatter
    ) -> TranscriptTurnState {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = timestamp(
                    object["timestamp"],
                    fractional: fractional,
                    whole: whole
                  ) else { continue }
            guard timestamp >= lastPromptAt else { return .active }
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else { continue }
            switch eventType {
            case "task_complete": return .completed
            case "turn_aborted": return .interrupted
            case "task_started": return .active
            default: continue
            }
        }
        return .active
    }

    private static func tailData(atPath path: String, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private static func timestamp(
        _ value: Any?,
        fractional: ISO8601DateFormatter,
        whole: ISO8601DateFormatter
    ) -> Date? {
        guard let value = value as? String else { return nil }
        return fractional.date(from: value) ?? whole.date(from: value)
    }
}
