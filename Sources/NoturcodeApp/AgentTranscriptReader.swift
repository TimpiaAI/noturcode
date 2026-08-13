import Foundation
import NoturcodeCore

enum AgentTranscriptSnapshot: Equatable, Sendable {
    case found([ChatTranscriptEntry])
    case missing
    case failed(String)
}

/// Reads the agents' local JSONL transcript. No Apple Events, terminal capture,
/// focus change, or process invocation is involved.
actor AgentTranscriptReader {
    private struct CacheEntry {
        var url: URL
        var modificationDate: Date?
        var byteOffset: UInt64
        var rollingData: Data
        var entries: [ChatTranscriptEntry]
    }

    private let maximumRollingBytes = 1_000_000

    private var cache: [SessionKey: CacheEntry] = [:]
    private var subagentCache: [String: CacheEntry] = [:]
    private let usesFixture = CommandLine.arguments.contains("--ui-test-hover-first")
        || CommandLine.arguments.contains("--ui-test-agent-conversation")

    func snapshot(_ session: TrackedSession) -> AgentTranscriptSnapshot {
        if usesFixture { return .found(Self.fixtureEntries) }
        guard let url = transcriptURL(for: session) else { return .missing }
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let fileSize = UInt64(max(0, values.fileSize ?? 0))
            if let cached = cache[session.key],
               cached.url == url,
               cached.byteOffset == fileSize,
               cached.modificationDate == values.contentModificationDate {
                return .found(cached.entries)
            }

            var rollingData: Data
            if let cached = cache[session.key], cached.url == url,
               fileSize >= cached.byteOffset {
                rollingData = cached.rollingData
                if fileSize > cached.byteOffset {
                    rollingData.append(try data(at: url, offset: cached.byteOffset))
                }
                rollingData = boundedTail(rollingData, maximumBytes: maximumRollingBytes)
            } else {
                rollingData = try tailData(at: url, maximumBytes: UInt64(maximumRollingBytes))
            }
            let entries = AgentTranscriptParser.parse(data: rollingData, source: session.key.source, limit: 160)
            cache[session.key] = CacheEntry(
                url: url,
                modificationDate: values.contentModificationDate,
                byteOffset: fileSize,
                rollingData: rollingData,
                entries: entries
            )
            return .found(entries)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func snapshot(_ session: TrackedSession, subagentID: String) -> AgentTranscriptSnapshot {
        if usesFixture { return .found(Self.fixtureSubagentEntries) }
        guard session.key.source == .claude else { return .missing }
        guard let parentURL = transcriptURL(for: session) else { return .missing }
        let normalizedID = subagentID.hasPrefix("agent-")
            ? String(subagentID.dropFirst("agent-".count))
            : subagentID
        let url = parentURL.deletingPathExtension()
            .appendingPathComponent("subagents/agent-\(normalizedID).jsonl")
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .missing }
        let cacheID = "\(session.key.description)|\(normalizedID)"
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let fileSize = UInt64(max(0, values.fileSize ?? 0))
            if let cached = subagentCache[cacheID],
               cached.url == url,
               cached.byteOffset == fileSize,
               cached.modificationDate == values.contentModificationDate {
                return .found(cached.entries)
            }
            var rollingData: Data
            if let cached = subagentCache[cacheID], cached.url == url, fileSize >= cached.byteOffset {
                rollingData = cached.rollingData
                if fileSize > cached.byteOffset {
                    rollingData.append(try data(at: url, offset: cached.byteOffset))
                }
                rollingData = boundedTail(rollingData, maximumBytes: maximumRollingBytes)
            } else {
                rollingData = try tailData(at: url, maximumBytes: UInt64(maximumRollingBytes))
            }
            let entries = AgentTranscriptParser.parse(data: rollingData, source: .claude, limit: 160)
            subagentCache[cacheID] = CacheEntry(
                url: url,
                modificationDate: values.contentModificationDate,
                byteOffset: fileSize,
                rollingData: rollingData,
                entries: entries
            )
            return .found(entries)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func transcriptURL(for session: TrackedSession) -> URL? {
        if let path = session.transcriptPath, FileManager.default.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let cached = cache[session.key], FileManager.default.isReadableFile(atPath: cached.url.path) {
            return cached.url
        }
        switch session.key.source {
        case .claude:
            return findClaudeTranscript(sessionID: session.key.sessionID)
        case .codex:
            return findCodexTranscript(sessionID: session.key.sessionID)
        case .gemini, .opencode, .grok, .harness:
            return nil
        }
    }

    private func findClaudeTranscript(sessionID: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let filename = "\(sessionID).jsonl"
        for case let url as URL in enumerator where url.lastPathComponent == filename {
            return url
        }
        return nil
    }

    private func findCodexTranscript(sessionID: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }
        let needles = ["\"id\":\"\(sessionID)\"", "\"id\": \"\(sessionID)\""]
        for (url, _) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(160) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 32_768)) ?? Data()
            let head = String(decoding: data, as: UTF8.self)
            if needles.contains(where: head.contains) { return url }
        }
        return nil
    }

    private func tailData(at url: URL, maximumBytes: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > maximumBytes ? size - maximumBytes : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[data.index(after: newline)...])
        }
        return data
    }

    private func data(at url: URL, offset: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    private func boundedTail(_ data: Data, maximumBytes: Int) -> Data {
        guard data.count > maximumBytes else { return data }
        let start = data.index(data.endIndex, offsetBy: -maximumBytes)
        let suffix = data[start...]
        guard let newline = suffix.firstIndex(of: 0x0A) else { return Data(suffix) }
        return Data(suffix[suffix.index(after: newline)...])
    }

    private static let fixtureEntries: [ChatTranscriptEntry] = [
        ChatTranscriptEntry(
            id: "fixture-user",
            kind: .user,
            text: "Make the floating session feel native and compact.",
            imagePaths: ["/tmp/noturcode-demo/reference.png"]
        ),
        ChatTranscriptEntry(
            id: "fixture-assistant",
            kind: .assistant,
            text: """
            ## Live renderer

            **Markdown** stays readable, and model diagrams keep their shape. Review Sources/NoturcodeApp/SessionViews.swift.

            ```swift
            let status = "working"
            ```

            ┌─────────┐
            │ prompt  │
            └────┬────┘
                 ▼
            """,
            model: "claude-sonnet-4-5"
        ),
        ChatTranscriptEntry(
            id: "fixture-tool",
            kind: .tool,
            title: "Agent verify UI",
            text: "xcodebuild test -project Noturcode.xcodeproj -scheme Noturcode",
            detail: "23 tests passed with zero failures.",
            model: "claude-sonnet-4-5"
        ),
        ChatTranscriptEntry(
            id: "fixture-assistant-2",
            kind: .assistant,
            text: "The compact glass card is ready. The attached reference stays available for preview.",
            model: "claude-sonnet-4-5"
        )
    ]

    private static let fixtureSubagentEntries: [ChatTranscriptEntry] = [
        ChatTranscriptEntry(
            id: "fixture-agent-user",
            kind: .user,
            text: "Inspect the focused component and report the exact findings."
        ),
        ChatTranscriptEntry(
            id: "fixture-agent-tool",
            kind: .tool,
            title: "Read component",
            text: "SessionViews.swift",
            detail: "Loaded the orchestration and conversation surfaces.",
            model: "claude-opus-5"
        ),
        ChatTranscriptEntry(
            id: "fixture-agent-assistant",
            kind: .assistant,
            text: "This is the selected agent's own conversation.",
            model: "claude-opus-5"
        )
    ]
}
