import Darwin
import Foundation

public enum RemoteImageUploadPlan {
    public static let maximumImageBytes = 20 * 1_024 * 1_024

    public static func fileName(uuid: UUID = UUID()) -> String {
        "image-\(uuid.uuidString).png"
    }

    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              host.count <= 255,
              !host.hasPrefix("-"),
              host.filter({ $0 == "@" }).count <= 1 else { return false }

        let parts = host.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let address = String(parts.last ?? "")
        if address.contains("[") || address.contains("]") {
            guard address.hasPrefix("["), address.hasSuffix("]"),
                  address.dropFirst().dropLast().contains(":") else { return false }
        }

        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-@:%[]"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func sshArguments(
        host: String,
        fileName: String,
        controlPath: String? = nil
    ) -> [String]? {
        guard isValidHost(host), isValidFileName(fileName) else { return nil }
        if let controlPath, !isValidControlPath(controlPath) { return nil }
        let remoteDirectory = ".cache/noturcode/attachments"
        let command = "umask 077; directory=\"$HOME/\(remoteDirectory)\"; "
            + "destination=\"$directory/\(fileName)\"; "
            + "mkdir -p \"$directory\" && "
            + "chmod 700 \"$HOME/.cache/noturcode\" \"$directory\" && "
            + "trap 'rm -f \"$destination\"' EXIT HUP INT TERM && "
            + "cat > \"$destination\" && chmod 600 \"$destination\" && "
            + "trap - EXIT HUP INT TERM && printf '%s' \"$destination\""
        var arguments: [String] = []
        if let controlPath {
            arguments += [
                "-S", controlPath,
                "-o", "ControlMaster=no",
                "-o", "ProxyCommand=/usr/bin/false"
            ]
        }
        arguments += [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "--", host,
            command
        ]
        return arguments
    }

    public static func validatedRemotePath(_ output: String) -> String? {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path.count <= 4_096 else { return nil }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-/"))
        guard path.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return path
    }

    private static func isValidFileName(_ fileName: String) -> Bool {
        guard fileName.hasPrefix("image-"),
              fileName.hasSuffix(".png"),
              fileName.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: ".-"))
        return fileName.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func isValidControlPath(_ path: String) -> Bool {
        guard path.hasPrefix("/tmp/noturcode-ssh."),
              path.hasSuffix("/control"),
              path.utf8.count < 104 else { return false }
        let suffix = path.dropFirst("/tmp/noturcode-ssh.".count).dropLast("/control".count)
        guard suffix.count == 6,
              suffix.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-/"))
        return path.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func isUsableControlSocket(_ path: String) -> Bool {
        guard isValidControlPath(path) else { return false }
        var socketStatus = stat()
        guard lstat(path, &socketStatus) == 0,
              socketStatus.st_uid == getuid(),
              socketStatus.st_mode & S_IFMT == S_IFSOCK else { return false }
        var directoryStatus = stat()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(directory, &directoryStatus) == 0,
              directoryStatus.st_uid == getuid(),
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_mode & 0o077 == 0 else { return false }
        return true
    }
}
