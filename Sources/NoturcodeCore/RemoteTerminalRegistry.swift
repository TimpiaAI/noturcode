import Darwin
import Foundation

public final class RemoteTerminalRegistry: @unchecked Sendable {
    private struct Entry: Codable {
        let terminalSessionID: String
        let session: TrackedSession?

        init(terminalSessionID: String, session: TrackedSession? = nil) {
            self.terminalSessionID = terminalSessionID
            self.session = session
        }
    }

    public let directoryURL: URL

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = support
                .appendingPathComponent("Noturcode", isDirectory: true)
                .appendingPathComponent("remote-terminals", isDirectory: true)
        }
    }

    public func register(terminalSessionID: String) throws {
        let target = TerminalTarget(sessionID: terminalSessionID)
        guard target.applicationKind == .iterm,
              target.identity?.remoteHost?.isEmpty == false,
              let fileURL = fileURL(for: target.uniqueID) else {
            throw POSIXError(.EINVAL)
        }
        // Opening a new workspace in the same pane starts a new lifecycle.
        // Only live hook events may attach a session snapshot.
        let data = try JSONEncoder().encode(Entry(terminalSessionID: terminalSessionID))
        try SecureLocalStorage.writePrivate(data, to: fileURL)
    }

    public func remember(_ session: TrackedSession) throws {
        guard let sessionTarget = session.terminal,
              let fileURL = fileURL(for: sessionTarget.uniqueID),
              let entry = loadEntry(at: fileURL) else {
            throw POSIXError(.ENOENT)
        }
        let registeredTarget = TerminalTarget(sessionID: entry.terminalSessionID)
        guard registeredTarget.applicationKind == .iterm,
              registeredTarget.identity?.remoteHost?.isEmpty == false,
              registeredTarget.uniqueID == sessionTarget.uniqueID else {
            throw POSIXError(.EINVAL)
        }
        var snapshot = session
        snapshot.terminal = registeredTarget
        let data = try JSONEncoder().encode(Entry(
            terminalSessionID: entry.terminalSessionID,
            session: snapshot
        ))
        try SecureLocalStorage.writePrivate(data, to: fileURL)
    }

    public func forgetSession(_ key: SessionKey) throws {
        for (fileURL, entry, target) in validEntries() where entry.session?.key == key {
            let data = try JSONEncoder().encode(Entry(terminalSessionID: target.sessionID))
            try SecureLocalStorage.writePrivate(data, to: fileURL)
        }
    }

    public func unregister(terminalSessionID: String) throws {
        let target = TerminalTarget(sessionID: terminalSessionID)
        guard let fileURL = fileURL(for: target.uniqueID) else {
            throw POSIXError(.EINVAL)
        }
        var status = stat()
        if lstat(fileURL.path, &status) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EPERM)
        }
        guard unlink(fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func targets() -> [TerminalTarget] {
        validEntries().map { $0.target }
        .sorted { $0.uniqueID < $1.uniqueID }
    }

    public func sessions() -> [TrackedSession] {
        validEntries().compactMap { _, entry, target in
            guard var session = entry.session else { return nil }
            session.terminal = target
            return session
        }
        .sorted { $0.lastPromptAt > $1.lastPromptAt }
    }

    private func validEntries() -> [(fileURL: URL, entry: Entry, target: TerminalTarget)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { fileURL in
            guard fileURL.pathExtension == "json",
                  let expectedID = normalizedUUID(fileURL.deletingPathExtension().lastPathComponent),
                  let entry = loadEntry(at: fileURL) else { return nil }
            let target = TerminalTarget(sessionID: entry.terminalSessionID)
            guard target.applicationKind == .iterm,
                  target.identity?.remoteHost?.isEmpty == false,
                  target.uniqueID.uppercased() == expectedID else { return nil }
            return (fileURL, entry, target)
        }
    }

    private func loadEntry(at fileURL: URL) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func fileURL(for uniqueID: String) -> URL? {
        guard let uuid = normalizedUUID(uniqueID) else { return nil }
        return directoryURL.appendingPathComponent("\(uuid).json", isDirectory: false)
    }

    private func normalizedUUID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString
    }
}
