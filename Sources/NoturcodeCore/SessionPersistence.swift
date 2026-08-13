import Darwin
import Foundation

public enum SecureLocalStorage {
    public static let directoryPermissions = 0o700
    public static let filePermissions = 0o600

    public static func ensurePrivateDirectory(at url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXError(.EPERM)
            }
        } else {
            guard errno == ENOENT else { throw posixError() }
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
            guard lstat(url.path, &status) == 0,
                  status.st_uid == getuid(),
                  status.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXError(.EPERM)
            }
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: directoryPermissions],
            ofItemAtPath: url.path
        )
    }

    public static func writePrivate(_ data: Data, to url: URL) throws {
        try ensurePrivateDirectory(at: url.deletingLastPathComponent())
        try validateOwnedRegularFileIfPresent(at: url)
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(filePermissions)
        )
        guard descriptor >= 0 else { throw posixError() }
        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile { unlink(temporaryURL.path) }
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw posixError() }
        guard rename(temporaryURL.path, url.path) == 0 else { throw posixError() }
        shouldRemoveTemporaryFile = false
    }

    public static func appendPrivate(_ data: Data, to url: URL) throws {
        try ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, mode_t(filePermissions))
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EPERM)
        }
        guard fchmod(descriptor, mode_t(filePermissions)) == 0 else {
            throw posixError()
        }
        try writeAll(data, to: descriptor)
    }

    private static func validateOwnedRegularFileIfPresent(at url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFREG else {
                throw POSIXError(.EPERM)
            }
        } else if errno != ENOENT {
            throw posixError()
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                guard count > 0 else {
                    throw posixError()
                }
                offset += count
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

public final class SessionPersistence: @unchecked Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let override = ProcessInfo.processInfo.environment["NOTURCODE_STATE_PATH"], !override.isEmpty {
            self.fileURL = URL(fileURLWithPath: override)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support.appendingPathComponent("Noturcode", isDirectory: true)
                .appendingPathComponent("connected-sessions.json")
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> [TrackedSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([TrackedSession].self, from: data)) ?? []
    }

    public func save(_ sessions: [TrackedSession]) throws {
        let data = try encoder.encode(sessions)
        try SecureLocalStorage.writePrivate(data, to: fileURL)
    }
}
