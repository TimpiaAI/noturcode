import Foundation

public enum NoturcodeSummaryContract {
    /// Keep old summaries readable. Noturcode no longer tells agents to create
    /// a special response format.
    public static func isDisplayable(_ message: String?) -> Bool {
        guard let message else { return false }
        let normalized = message.lowercased()
        return normalized.contains("noturcode summary")
            && normalized.contains("done:")
            && normalized.contains("needs you:")
    }

}
