import Foundation
import NoturcodeCore

enum AgentTranscriptSnapshot: Equatable, Sendable {
    case found([ChatTranscriptEntry])
    case missing
    case failed(String)
}

/// Reads local agent transcript files. It does not use Apple Events, terminal capture,
/// or focus changes. OpenCode uses the system sqlite3 CLI in read-only mode and
/// queries only session, message, and part rows.
actor AgentTranscriptReader {
    private struct CacheEntry {
        var url: URL
        var modificationDate: Date?
        var byteOffset: UInt64
        var rollingData: Data
        var entries: [ChatTranscriptEntry]
        var lastAccess: UInt64 = 0
    }

    private let maximumRollingBytes = 1_000_000
    private let maximumCachedSessions = 48
    private let maximumCachedSubagents = 96

    private var cache: [SessionKey: CacheEntry] = [:]
    private var subagentCache: [String: CacheEntry] = [:]
    private var nextDiscoveryAt: [SessionKey: Date] = [:]
    private var cacheClock: UInt64 = 0
    private let usesFixture = CommandLine.arguments.contains("--ui-test-hover-first")
        || CommandLine.arguments.contains("--ui-test-agent-conversation")

    func snapshot(_ session: TrackedSession) -> AgentTranscriptSnapshot {
        if usesFixture { return .found(Self.fixtureEntries) }
        guard let url = transcriptURL(for: session) else { return .missing }
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let fileSize = UInt64(max(0, values.fileSize ?? 0))
            if let cached = cachedEntry(for: session.key),
               cached.url == url,
               cached.byteOffset == fileSize,
               cached.modificationDate == values.contentModificationDate {
                return .found(cached.entries)
            }

            if session.key.source == .opencode, isOpenCodeDatabase(url) {
                let entries = try readOpenCodeDatabase(at: url, sessionID: session.key.sessionID)
                store(CacheEntry(
                    url: url,
                    modificationDate: values.contentModificationDate,
                    byteOffset: fileSize,
                    rollingData: Data(),
                    entries: entries
                ), for: session.key)
                return .found(entries)
            }

            if url.path.contains("/Noturcode/native-transcripts/") {
                let rollingData = try tailData(at: url, maximumBytes: UInt64(maximumRollingBytes))
                let entries = AgentTranscriptParser.parse(
                    data: rollingData,
                    source: session.key.source,
                    limit: 160
                )
                store(CacheEntry(
                    url: url,
                    modificationDate: values.contentModificationDate,
                    byteOffset: fileSize,
                    rollingData: rollingData,
                    entries: entries
                ), for: session.key)
                return .found(entries)
            }
            if session.key.source == .gemini || session.key.source == .grok {
                let rollingData = try tailData(at: url, maximumBytes: UInt64(maximumRollingBytes))
                let entries = parseProviderJSONL(
                    data: rollingData,
                    source: session.key.source,
                    sessionID: session.key.sessionID,
                    limit: 160
                )
                store(CacheEntry(
                    url: url,
                    modificationDate: values.contentModificationDate,
                    byteOffset: fileSize,
                    rollingData: rollingData,
                    entries: entries
                ), for: session.key)
                return .found(entries)
            }

            var rollingData: Data
            if let cached = cachedEntry(for: session.key), cached.url == url,
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
            store(CacheEntry(
                url: url,
                modificationDate: values.contentModificationDate,
                byteOffset: fileSize,
                rollingData: rollingData,
                entries: entries
            ), for: session.key)
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
            if let cached = cachedSubagentEntry(for: cacheID),
               cached.url == url,
               cached.byteOffset == fileSize,
               cached.modificationDate == values.contentModificationDate {
                return .found(cached.entries)
            }
            var rollingData: Data
            if let cached = cachedSubagentEntry(for: cacheID), cached.url == url, fileSize >= cached.byteOffset {
                rollingData = cached.rollingData
                if fileSize > cached.byteOffset {
                    rollingData.append(try data(at: url, offset: cached.byteOffset))
                }
                rollingData = boundedTail(rollingData, maximumBytes: maximumRollingBytes)
            } else {
                rollingData = try tailData(at: url, maximumBytes: UInt64(maximumRollingBytes))
            }
            let entries = AgentTranscriptParser.parse(data: rollingData, source: .claude, limit: 160)
            storeSubagent(CacheEntry(
                url: url,
                modificationDate: values.contentModificationDate,
                byteOffset: fileSize,
                rollingData: rollingData,
                entries: entries
            ), for: cacheID)
            return .found(entries)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func transcriptURL(for session: TrackedSession) -> URL? {
        if let path = session.transcriptPath {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.isReadableFile(atPath: url.path),
               session.key.source != .opencode || !url.pathExtension.lowercased().contains("db") || url.lastPathComponent == "opencode.db" {
                nextDiscoveryAt[session.key] = nil
                return url
            }
        }
        if let cached = cachedEntry(for: session.key), FileManager.default.isReadableFile(atPath: cached.url.path) {
            return cached.url
        }
        let now = Date()
        if let retryAt = nextDiscoveryAt[session.key], retryAt > now { return nil }
        let discovered: URL? = switch session.key.source {
        case .claude:
            findClaudeTranscript(sessionID: session.key.sessionID)
        case .codex:
            findCodexTranscript(sessionID: session.key.sessionID)
        case .gemini:
            findGeminiTranscript(sessionID: session.key.sessionID)
        case .opencode:
            findOpenCodeDatabase(sessionID: session.key.sessionID)
        case .grok:
            findGrokTranscript(sessionID: session.key.sessionID, cwd: session.cwd)
        case .harness:
            nil
        }
        nextDiscoveryAt[session.key] = discovered == nil ? now.addingTimeInterval(3) : nil
        return discovered
    }

    private func cachedEntry(for key: SessionKey) -> CacheEntry? {
        guard var entry = cache[key] else { return nil }
        cacheClock &+= 1
        entry.lastAccess = cacheClock
        cache[key] = entry
        return entry
    }

    private func cachedSubagentEntry(for key: String) -> CacheEntry? {
        guard var entry = subagentCache[key] else { return nil }
        cacheClock &+= 1
        entry.lastAccess = cacheClock
        subagentCache[key] = entry
        return entry
    }

    private func store(_ entry: CacheEntry, for key: SessionKey) {
        cacheClock &+= 1
        var entry = entry
        entry.lastAccess = cacheClock
        cache[key] = entry
        while cache.count > maximumCachedSessions,
              let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache.removeValue(forKey: oldest)
            nextDiscoveryAt.removeValue(forKey: oldest)
        }
    }

    private func storeSubagent(_ entry: CacheEntry, for key: String) {
        cacheClock &+= 1
        var entry = entry
        entry.lastAccess = cacheClock
        subagentCache[key] = entry
        while subagentCache.count > maximumCachedSubagents,
              let oldest = subagentCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            subagentCache.removeValue(forKey: oldest)
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

    private func findGeminiTranscript(sessionID: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }

        let shortID = String(sessionID.prefix(8)).lowercased()
        var candidates: [(url: URL, modified: Date, filenameMatch: Bool)] = []
        for case let url as URL in enumerator where
            url.pathExtension.lowercased() == "jsonl" || url.pathExtension.lowercased() == "json" {
            guard url.lastPathComponent.hasPrefix("session-"),
                  url.pathComponents.dropLast().last == "chats" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let name = url.lastPathComponent.lowercased()
            candidates.append((url, values?.contentModificationDate ?? .distantPast, name.contains(shortID)))
        }
        let ordered = candidates.sorted {
            if $0.filenameMatch != $1.filenameMatch { return $0.filenameMatch }
            return $0.modified > $1.modified
        }
        for candidate in ordered.prefix(240) {
            if candidate.filenameMatch || jsonlContainsSessionID(at: candidate.url, sessionID: sessionID) {
                return candidate.url
            }
        }
        return nil
    }

    private func findGrokTranscript(sessionID: String, cwd: String?) -> URL? {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
        let sessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)
        let sessionDirectory = sessionsRoot
            .appendingPathComponent(encodedGrokCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let preferred = [
            sessionDirectory.appendingPathComponent("updates.jsonl"),
            sessionDirectory.appendingPathComponent("chat_history.jsonl")
        ]
        if let url = preferred.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) {
            return url
        }

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        var candidates: [(url: URL, modified: Date, preferred: Bool)] = []
        for case let url as URL in enumerator where ["updates.jsonl", "chat_history.jsonl"].contains(url.lastPathComponent) {
            guard url.deletingLastPathComponent().lastPathComponent == sessionID else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            candidates.append((url, values?.contentModificationDate ?? .distantPast, url.lastPathComponent == "updates.jsonl"))
        }
        return candidates.sorted {
            if $0.preferred != $1.preferred { return $0.preferred }
            return $0.modified > $1.modified
        }.first?.url
    }

    private func encodedGrokCWD(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "%2FUsers%2Fovipi" }
        return cwd.replacingOccurrences(of: "/", with: "%2F")
    }

    private func findOpenCodeDatabase(sessionID: String) -> URL? {
        for url in openCodeDatabaseURLs() where FileManager.default.isReadableFile(atPath: url.path) {
            if databaseContainsSession(at: url, sessionID: sessionID) { return url }
        }
        return nil
    }

    private func openCodeDatabaseURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []
        if let dataDirectory = ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"], !dataDirectory.isEmpty {
            roots.append(URL(fileURLWithPath: dataDirectory, isDirectory: true))
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            roots.append(URL(fileURLWithPath: xdg, isDirectory: true))
        }
        roots.append(home.appendingPathComponent(".local/share", isDirectory: true))
        roots.append(home.appendingPathComponent("Library/Application Support", isDirectory: true))
        var result: [URL] = []
        for root in roots {
            let url = root.appendingPathComponent("opencode/opencode.db")
            if !result.contains(url) { result.append(url) }
        }
        return result
    }

    private func isOpenCodeDatabase(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare("opencode.db") == .orderedSame
    }

    private func jsonlContainsSessionID(at url: URL, sessionID: String) -> Bool {
        guard let data = try? headData(at: url, maximumBytes: 32_768),
              let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if object["sessionId"] as? String == sessionID { return true }
            if let set = object["$set"] as? [String: Any], set["sessionId"] as? String == sessionID { return true }
        }
        return false
    }

    private func databaseContainsSession(at url: URL, sessionID: String) -> Bool {
        guard let data = try? runSQLite(
            database: url,
            query: "SELECT id FROM session WHERE id = \(sqlLiteral(sessionID)) LIMIT 1;"
        ),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return !rows.isEmpty
    }

    private func parseProviderJSONL(
        data: Data,
        source: AgentSource,
        sessionID: String,
        limit: Int
    ) -> [ChatTranscriptEntry] {
        switch source {
        case .gemini:
            return parseGeminiJSONL(data: data, sessionID: sessionID, limit: limit)
        case .grok:
            return parseGrokJSONL(data: data, sessionID: sessionID, limit: limit)
        default:
            return []
        }
    }

    private func parseGeminiJSONL(data: Data, sessionID: String, limit: Int) -> [ChatTranscriptEntry] {
        var messages: [String: [String: Any]] = [:]
        var order: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = jsonObject(line) else { continue }
            if let rewindID = object["$rewindTo"] as? String {
                if let index = order.firstIndex(of: rewindID) {
                    for removed in order[index...] { messages.removeValue(forKey: removed) }
                    order.removeSubrange(index...)
                } else {
                    messages.removeAll()
                    order.removeAll()
                }
                continue
            }
            if let set = object["$set"] as? [String: Any] {
                if let metadataSessionID = set["sessionId"] as? String,
                   metadataSessionID != sessionID,
                   !sessionID.isEmpty { continue }
                if let initial = set["messages"] as? [[String: Any]] {
                    messages.removeAll()
                    order.removeAll()
                    for message in initial { upsertGeminiMessage(message, into: &messages, order: &order) }
                }
                continue
            }
            if let metadataSessionID = object["sessionId"] as? String,
               metadataSessionID != sessionID,
               !sessionID.isEmpty { continue }
            if let initial = object["messages"] as? [[String: Any]] {
                for message in initial { upsertGeminiMessage(message, into: &messages, order: &order) }
                continue
            }
            if object["id"] is String { upsertGeminiMessage(object, into: &messages, order: &order) }
        }

        var entries: [ChatTranscriptEntry] = []
        for id in order {
            guard let message = messages[id] else { continue }
            appendGeminiMessage(message, recordID: id, to: &entries)
        }
        return boundedEntries(entries, limit: limit)
    }

    private func upsertGeminiMessage(
        _ message: [String: Any],
        into messages: inout [String: [String: Any]],
        order: inout [String]
    ) {
        guard let id = message["id"] as? String, !id.isEmpty else { return }
        if messages[id] == nil { order.append(id) }
        messages[id] = message
    }

    private func appendGeminiMessage(
        _ message: [String: Any],
        recordID: String,
        to entries: inout [ChatTranscriptEntry]
    ) {
        let type = (message["type"] as? String)?.lowercased() ?? ""
        let timestamp = providerDate(message["timestamp"])
        let model = message["model"] as? String
        let content = contentText(providerValue(message, keys: ["displayContent", "content"]))
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !trimmed.hasPrefix("<session_context>"),
           !trimmed.hasPrefix("<hook_context>") {
            let kind: ChatTranscriptKind
            switch type {
            case "user": kind = .user
            case "gemini", "assistant", "model": kind = .assistant
            case "error", "warning", "info": kind = .system
            default: kind = .system
            }
            entries.append(ChatTranscriptEntry(
                id: "gemini-\(recordID)-\(type)",
                kind: kind,
                text: content,
                timestamp: timestamp,
                imagePaths: imagePaths(in: content),
                model: model
            ))
        }

        guard let toolCalls = message["toolCalls"] as? [[String: Any]] else { return }
        for (index, tool) in toolCalls.enumerated() {
            let toolID = (tool["id"] as? String) ?? "\(recordID)-tool-\(index)"
            let name = (tool["displayName"] as? String)
                ?? (tool["name"] as? String)
                ?? "Tool"
            let input = prettyProviderJSON(providerValue(tool, keys: ["args", "input", "rawInput"])) ?? ""
            let output = contentText(providerValue(tool, keys: ["result", "output", "rawOutput"]))
            entries.append(ChatTranscriptEntry(
                id: "gemini-tool-\(toolID)",
                kind: .tool,
                title: name,
                text: input,
                detail: output.isEmpty ? nil : output,
                timestamp: timestamp,
                imagePaths: imagePaths(in: input),
                model: model
            ))
        }
    }

    private func parseGrokJSONL(data: Data, sessionID: String, limit: Int) -> [ChatTranscriptEntry] {
        var entries: [ChatTranscriptEntry] = []
        var toolIndexes: [String: Int] = [:]
        var assistantText = ""
        var assistantID: String?
        var userText = ""
        var userID: String?
        var ordinal = 0

        func flushUser() {
            let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<system-reminder>") else {
                userText = ""
                userID = nil
                return
            }
            entries.append(ChatTranscriptEntry(
                id: "grok-user-\(userID ?? stableProviderID(text))",
                kind: .user,
                text: text,
                imagePaths: imagePaths(in: text)
            ))
            userText = ""
            userID = nil
        }

        func flushAssistant() {
            let text = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                assistantText = ""
                assistantID = nil
                return
            }
            entries.append(ChatTranscriptEntry(
                id: "grok-assistant-\(assistantID ?? stableProviderID(text))",
                kind: .assistant,
                text: text,
                imagePaths: imagePaths(in: text)
            ))
            assistantText = ""
            assistantID = nil
        }

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = jsonObject(line) else { continue }
            if let directType = object["type"] as? String,
               ["system", "user", "assistant", "tool"].contains(directType.lowercased()),
               object["content"] != nil {
                if directType.lowercased() == "user" {
                    flushAssistant()
                    flushUser()
                    let text = contentText(object["content"])
                    if !text.isEmpty { userText += text; userID = userID ?? object["id"] as? String }
                } else if directType.lowercased() == "assistant" {
                    flushUser()
                    flushAssistant()
                    let text = contentText(object["content"])
                    if !text.isEmpty { assistantText += text; assistantID = assistantID ?? object["id"] as? String }
                } else if directType.lowercased() == "tool" {
                    flushUser()
                    flushAssistant()
                    appendGrokTool(object, ordinal: ordinal, entries: &entries, toolIndexes: &toolIndexes)
                    ordinal += 1
                }
                continue
            }

            var update = object
            if let params = object["params"] as? [String: Any],
               let nested = params["update"] as? [String: Any] { update = nested }
            if let nested = object["update"] as? [String: Any] { update = nested }
            let type = ((update["sessionUpdate"] as? String) ?? (update["type"] as? String) ?? "").lowercased()
            let updateSessionID = (update["sessionId"] as? String) ?? (object["sessionId"] as? String)
            if let updateSessionID, !sessionID.isEmpty, updateSessionID != sessionID { continue }
            switch type {
            case "user_message_chunk":
                flushAssistant()
                let text = contentText(providerValue(update, keys: ["content", "text", "data"]))
                if !text.isEmpty { userText += text; userID = userID ?? update["messageId"] as? String }
            case "agent_message_chunk", "text":
                flushUser()
                let text = contentText(providerValue(update, keys: ["content", "text", "data"]))
                if !text.isEmpty {
                    assistantText += text
                    assistantID = assistantID ?? (update["messageId"] as? String) ?? (update["id"] as? String)
                }
            case "tool_call":
                flushUser()
                flushAssistant()
                appendGrokTool(update, ordinal: ordinal, entries: &entries, toolIndexes: &toolIndexes)
                ordinal += 1
            case "tool_call_update":
                updateGrokTool(update, entries: &entries, toolIndexes: &toolIndexes)
            case "plan":
                flushUser()
                flushAssistant()
                let planValue = providerValue(update, keys: ["entries", "plan"])
                let plan: String
                if let pretty = prettyProviderJSON(planValue) {
                    plan = pretty
                } else {
                    plan = contentText(planValue)
                }
                if !plan.isEmpty {
                    entries.append(ChatTranscriptEntry(
                        id: "grok-plan-\(ordinal)", kind: .tool, title: "Plan", text: plan
                    ))
                    ordinal += 1
                }
            case "result":
                let text = contentText(providerValue(update, keys: ["text", "data", "result"]))
                if !text.isEmpty { assistantText += text; assistantID = assistantID ?? update["messageId"] as? String }
            default:
                continue
            }
        }
        flushUser()
        flushAssistant()
        return boundedEntries(entries, limit: limit)
    }

    private func appendGrokTool(
        _ update: [String: Any],
        ordinal: Int,
        entries: inout [ChatTranscriptEntry],
        toolIndexes: inout [String: Int]
    ) {
        let callID = (update["toolCallId"] as? String)
            ?? (update["callID"] as? String)
            ?? (update["id"] as? String)
            ?? "call-\(ordinal)"
        let name = (update["toolName"] as? String)
            ?? (update["tool"] as? String)
            ?? (update["title"] as? String)
            ?? "Tool"
        let input = prettyProviderJSON(providerValue(update, keys: ["rawInput", "raw_input", "input"])) ?? ""
        let detail = contentText(providerValue(update, keys: ["rawOutput", "raw_output", "content"]))
        entries.append(ChatTranscriptEntry(
            id: "grok-tool-\(callID)",
            kind: .tool,
            title: name,
            text: input,
            detail: detail.isEmpty ? nil : detail,
            model: update["model"] as? String
        ))
        toolIndexes[callID] = entries.count - 1
    }

    private func updateGrokTool(
        _ update: [String: Any],
        entries: inout [ChatTranscriptEntry],
        toolIndexes: inout [String: Int]
    ) {
        let callID = (update["toolCallId"] as? String)
            ?? (update["callID"] as? String)
            ?? (update["id"] as? String)
        guard let callID else { return }
        guard let index = toolIndexes[callID] else {
            appendGrokTool(update, ordinal: entries.count, entries: &entries, toolIndexes: &toolIndexes)
            return
        }
        let detail = contentText(providerValue(update, keys: ["rawOutput", "raw_output", "content"]))
        if !detail.isEmpty { entries[index].detail = detail }
        if let name = update["toolName"] as? String { entries[index].title = name }
    }

    private func readOpenCodeDatabase(at url: URL, sessionID: String) throws -> [ChatTranscriptEntry] {
        let query = """
        SELECT m.id AS message_id, m.time_created AS message_time, m.data AS message_data,
               p.id AS part_id, p.time_created AS part_time, p.data AS part_data
        FROM message AS m
        LEFT JOIN part AS p ON p.message_id = m.id
        WHERE m.session_id = \(sqlLiteral(sessionID))
        ORDER BY m.time_created, m.id, p.time_created, p.id;
        """
        let data = try runSQLite(database: url, query: query)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var messageOrder: [String] = []
        var messages: [String: [String: Any]] = [:]
        var timestamps: [String: Date?] = [:]
        var parts: [String: [[String: Any]]] = [:]
        for row in rows {
            guard let messageID = row["message_id"] as? String else { continue }
            if messages[messageID] == nil {
                messageOrder.append(messageID)
                messages[messageID] = decodeJSONObject(row["message_data"])
                timestamps[messageID] = millisecondsDate(row["message_time"])
            }
            if let partID = row["part_id"] as? String, !partID.isEmpty,
               let part = decodeJSONObject(row["part_data"]) {
                parts[messageID, default: []].append(part.merging(["_id": partID]) { current, _ in current })
            }
        }

        var entries: [ChatTranscriptEntry] = []
        for messageID in messageOrder {
            guard let message = messages[messageID] else { continue }
            let role = (message["role"] as? String)?.lowercased() ?? "assistant"
            let model = (message["modelID"] as? String)
                ?? ((message["model"] as? [String: Any])?["modelID"] as? String)
            var textParts: [String] = []
            for part in parts[messageID] ?? [] {
                let type = (part["type"] as? String)?.lowercased() ?? ""
                if type == "text" || type == "reasoning" {
                    let text = contentText(providerValue(part, keys: ["text", "content"]))
                    if !text.isEmpty { textParts.append(text) }
                }
                if type == "tool" {
                    appendOpenCodeTool(part, timestamp: timestamps[messageID] ?? nil, model: model, to: &entries)
                }
            }
            let text = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let kind: ChatTranscriptKind = role == "user" ? .user : role == "system" ? .system : .assistant
            entries.append(ChatTranscriptEntry(
                id: "opencode-\(messageID)",
                kind: kind,
                text: text,
                timestamp: timestamps[messageID] ?? nil,
                imagePaths: imagePaths(in: text),
                model: model
            ))
        }
        return boundedEntries(entries, limit: 160)
    }

    private func appendOpenCodeTool(
        _ part: [String: Any],
        timestamp: Date?,
        model: String?,
        to entries: inout [ChatTranscriptEntry]
    ) {
        let toolName = (part["tool"] as? String) ?? (part["name"] as? String) ?? "Tool"
        let state = part["state"] as? [String: Any]
        let stateInput = state.flatMap { providerValue($0, keys: ["input"]) }
        let inputValue = stateInput ?? part["input"]
        let input = prettyProviderJSON(inputValue) ?? ""
        let stateDetail = state.flatMap { providerValue($0, keys: ["output", "error"]) }
        let partDetail = providerValue(part, keys: ["output", "content"])
        let detailValue = stateDetail ?? partDetail
        let detail = contentText(detailValue)
        let callID = (part["callID"] as? String) ?? (part["callId"] as? String) ?? (part["_id"] as? String) ?? UUID().uuidString
        entries.append(ChatTranscriptEntry(
            id: "opencode-tool-\(callID)",
            kind: .tool,
            title: toolName,
            text: input,
            detail: detail.isEmpty ? nil : detail,
            timestamp: timestamp,
            imagePaths: imagePaths(in: input),
            model: model
        ))
    }

    private func runSQLite(database: URL, query: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", "-cmd", ".timeout 100", database.path, query]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "Noturcode.OpenCodeDatabase", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "OpenCode database query failed." : message])
        }
        return result
    }

    private func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func providerValue(_ object: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = object[key] { return value }
        }
        return nil
    }

    private func decodeJSONObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func contentText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let array = value as? [Any] { return array.map(contentText).filter { !$0.isEmpty }.joined(separator: "\n") }
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String { return text }
            if let data = object["data"] as? String { return data }
            if let output = object["output"] { return contentText(output) }
            if let result = object["result"] { return contentText(result) }
            if let content = object["content"] { return contentText(content) }
        }
        return ""
    }

    private func prettyProviderJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            guard let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return string }
            return String(decoding: pretty, as: UTF8.self)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func providerDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private func millisecondsDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue / 1_000) }
        if let string = value as? String, let number = Double(string) { return Date(timeIntervalSince1970: number / 1_000) }
        return nil
    }

    private func stableProviderID(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func boundedEntries(_ entries: [ChatTranscriptEntry], limit: Int) -> [ChatTranscriptEntry] {
        let boundedLimit = max(1, limit)
        guard entries.count > boundedLimit else { return entries }
        let recentIDs = Set(entries.suffix(boundedLimit).map(\.id))
        let conversationIDs = Set(entries.filter { $0.kind == .user || $0.kind == .assistant }.suffix(20).map(\.id))
        return entries.filter { recentIDs.contains($0.id) || conversationIDs.contains($0.id) }
    }

    private func headData(at url: URL, maximumBytes: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        return try handle.read(upToCount: Int(maximumBytes)) ?? Data()
    }

    private func imagePaths(in text: String) -> [String] {
        let pattern = #"(/[^\"]+?\.(?:png|jpe?g|gif|webp|heic|tiff?))(?=[\"\s\n]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let paths: [String] = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        }
        return paths.reduce(into: [String]()) { result, path in
            if !result.contains(path) { result.append(path) }
        }
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
