import Foundation

public enum TranscriptRunStateDetector {
    public static func turnCompleted(
        atPath path: String,
        source: AgentSource,
        after lastPromptAt: Date,
        maximumBytes: Int = 256 * 1_024
    ) -> Bool {
        guard let data = tailData(atPath: path, maximumBytes: maximumBytes) else { return false }
        return turnCompleted(data: data, source: source, after: lastPromptAt)
    }

    public static func turnCompleted(data: Data, source: AgentSource, after lastPromptAt: Date) -> Bool {
        guard source == .claude else { return false }
        var completed = false

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = timestamp(object["timestamp"]),
                  timestamp >= lastPromptAt,
                  let type = object["type"] as? String else { continue }

            if type == "user" {
                completed = false
                continue
            }
            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let stopReason = message["stop_reason"] as? String else { continue }
            completed = stopReason == "end_turn"
        }
        return completed
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

    private static func timestamp(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
