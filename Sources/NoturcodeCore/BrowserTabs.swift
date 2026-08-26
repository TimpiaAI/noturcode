import Foundation

public struct BrowserTabRecord: Identifiable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let windowIdentifier: Int
    public let tabIndex: Int
    public let title: String
    public let url: String
    public let isActive: Bool

    public var id: String {
        "\(bundleIdentifier):\(windowIdentifier):\(tabIndex)"
    }

    public init(
        bundleIdentifier: String,
        windowIdentifier: Int,
        tabIndex: Int,
        title: String,
        url: String,
        isActive: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowIdentifier = windowIdentifier
        self.tabIndex = tabIndex
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}

public enum BrowserTabWireParser {
    private static let fieldSeparator = Character(UnicodeScalar(31))
    private static let rowSeparator = Character(UnicodeScalar(30))

    public static func parse(_ payload: String, bundleIdentifier: String) -> [BrowserTabRecord] {
        let records: [BrowserTabRecord] = payload
            .split(separator: rowSeparator, omittingEmptySubsequences: true)
            .compactMap { row -> BrowserTabRecord? in
                let fields = row.split(
                    separator: fieldSeparator,
                    maxSplits: 4,
                    omittingEmptySubsequences: false
                ).map(String.init)
                guard fields.count == 5,
                      let windowIdentifier = Int(fields[0]),
                      let tabIndex = Int(fields[1]) else { return nil }
                return BrowserTabRecord(
                    bundleIdentifier: bundleIdentifier,
                    windowIdentifier: windowIdentifier,
                    tabIndex: tabIndex,
                    title: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
                    url: fields[3].trimmingCharacters(in: .whitespacesAndNewlines),
                    isActive: fields[4] == "1"
                )
            }
        return records.filter(\.isActive) + records.filter { !$0.isActive }
    }
}
