import Darwin
import Foundation

public final class RemoteTerminalRegistry: @unchecked Sendable {
    private struct Entry: Codable {
        let terminalSessionID: String
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
        let data = try JSONEncoder().encode(Entry(terminalSessionID: terminalSessionID))
        try SecureLocalStorage.writePrivate(data, to: fileURL)
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
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { fileURL -> TerminalTarget? in
            guard fileURL.pathExtension == "json",
                  let expectedID = normalizedUUID(fileURL.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: fileURL),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
            let target = TerminalTarget(sessionID: entry.terminalSessionID)
            guard target.applicationKind == .iterm,
                  target.identity?.remoteHost?.isEmpty == false,
                  target.uniqueID.uppercased() == expectedID else { return nil }
            return target
        }
        .sorted { $0.uniqueID < $1.uniqueID }
    }

    private func fileURL(for uniqueID: String) -> URL? {
        guard let uuid = normalizedUUID(uniqueID) else { return nil }
        return directoryURL.appendingPathComponent("\(uuid).json", isDirectory: false)
    }

    private func normalizedUUID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString
    }
}
