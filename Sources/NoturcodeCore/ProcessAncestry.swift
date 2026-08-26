import Darwin
import Foundation

public struct ProcessAncestor: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var command: String

    public init(pid: Int32, parentPID: Int32, command: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.command = command
    }
}

public enum ProcessAncestry {
    private static let supportedAgentNames: Set<String> = [
        "codex", "claude", "gemini", "pi", "omp", "hermes", "hermes-agent",
        "hermes-acp", "opencode", "grok", "node", "bun"
    ]

    public static func agentProcessID(startingAt startPID: Int32 = getppid()) -> Int32? {
        var pid = startPID
        var fallback: Int32?
        for _ in 0..<16 where pid > 1 {
            guard let ancestor = inspect(pid: pid) else { break }
            let name = URL(fileURLWithPath: ancestor.command).lastPathComponent.lowercased()
            if isAgentProcess(ancestor.command) && name != "node" && name != "bun" {
                return pid
            }
            if fallback == nil, name == "node" || name == "bun" {
                fallback = pid
            }
            pid = ancestor.parentPID
        }
        return fallback
    }

    public static func isAgentProcess(_ command: String) -> Bool {
        let normalized = command.lowercased()
        let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        let isHermesPython = normalized.contains("/.hermes/hermes-agent/venv/bin/python")
        return supportedAgentNames.contains(name)
            || name.hasPrefix("codex-")
            || name.hasPrefix("claude-")
            || isHermesPython
    }

    public static func inspect(pid: Int32) -> ProcessAncestor? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "ppid=", "-o", "comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return nil }
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let parentPID = Int32(fields[0]) else { return nil }
            return ProcessAncestor(pid: pid, parentPID: parentPID, command: String(fields[1]))
        } catch {
            return nil
        }
    }

    /// Returns the controlling terminal reported by `ps` (for example
    /// `ttys005`). GUI processes and exited processes do not have one.
    public static func terminalTTY(pid: Int32) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "tty="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let tty = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !tty.isEmpty, tty != "??", tty != "?" else { return nil }
            return tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        } catch {
            return nil
        }
    }
}
