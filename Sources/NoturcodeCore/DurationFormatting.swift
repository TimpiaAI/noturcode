import Foundation

public enum DurationFormatting {
    public static func compact(from start: Date, to end: Date = Date()) -> String {
        let total = max(0, Int(end.timeIntervalSince(start)))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return "\(hours)h \(minutes)m"
    }

    public static func relative(from date: Date, to now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        return "\(compact(from: date, to: now)) ago"
    }

    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM tok", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            let value = Double(count) / 1_000
            return value >= 100 ? String(format: "%.0fk tok", value) : String(format: "%.1fk tok", value)
        }
        return "\(count) tok"
    }
}
