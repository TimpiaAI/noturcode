import Foundation

public struct TokenUsageCheckpoint: Codable, Equatable, Sendable {
    public var transcriptPath: String
    public var offset: UInt64
    public var total: Int

    public init(transcriptPath: String, offset: UInt64, total: Int) {
        self.transcriptPath = transcriptPath
        self.offset = offset
        self.total = total
    }
}

public final class TokenUsageCheckpointStore: @unchecked Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support.appendingPathComponent("Noturcode", isDirectory: true)
                .appendingPathComponent("token-checkpoints.json")
        }
    }

    public func checkpoint(for key: SessionKey) -> TokenUsageCheckpoint? {
        load()[key.description]
    }

    public func mark(_ key: SessionKey, transcriptPath: String, total: Int) {
        guard let offset = TranscriptTokenCounter.fileSize(path: transcriptPath) else { return }
        var values = load()
        values[key.description] = TokenUsageCheckpoint(
            transcriptPath: transcriptPath,
            offset: offset,
            total: total
        )
        save(values)
    }

    public func advance(_ key: SessionKey, transcriptPath: String, total: Int) {
        mark(key, transcriptPath: transcriptPath, total: total)
    }

    public func remove(_ key: SessionKey) {
        var values = load()
        values[key.description] = nil
        save(values)
    }

    private func load() -> [String: TokenUsageCheckpoint] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: TokenUsageCheckpoint].self, from: data)) ?? [:]
    }

    private func save(_ values: [String: TokenUsageCheckpoint]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? SecureLocalStorage.writePrivate(data, to: fileURL)
    }
}
