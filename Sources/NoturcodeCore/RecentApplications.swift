import Foundation

public struct RecentApplicationRecord: Identifiable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let processIdentifier: Int32

    public var id: String { bundleIdentifier.lowercased() }

    public init(bundleIdentifier: String, name: String, processIdentifier: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
    }
}

public struct RecentApplicationHistory: Equatable, Sendable {
    public private(set) var items: [RecentApplicationRecord] = []
    public let limit: Int

    public init(limit: Int = 3) {
        self.limit = max(1, limit)
    }

    public mutating func activate(_ application: RecentApplicationRecord) {
        items.removeAll { $0.id == application.id }
        items.insert(application, at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
    }

    public mutating func terminate(processIdentifier: Int32) {
        items.removeAll { $0.processIdentifier == processIdentifier }
    }
}
