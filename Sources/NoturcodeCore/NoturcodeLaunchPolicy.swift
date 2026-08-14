import Darwin
import Foundation

public enum NoturcodeLaunchPolicy {
    public static var defaultPauseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noturcode", isDirectory: true)
            .appendingPathComponent("automatic-launch-paused")
    }

    public static func isAutomaticLaunchPaused(at url: URL = defaultPauseURL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    public static func pauseAutomaticLaunch(at url: URL = defaultPauseURL) throws {
        try SecureLocalStorage.writePrivate(Data("paused\n".utf8), to: url)
    }

    public static func resumeAutomaticLaunch(at url: URL = defaultPauseURL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EPERM)
        }
        guard unlink(url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
