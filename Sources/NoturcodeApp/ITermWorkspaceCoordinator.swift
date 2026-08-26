import Foundation
import NoturcodeCore

struct ITermWorkspaceSummary: Sendable {
    let windows: Int
    let panes: Int
}

enum ITermWorkspaceError: LocalizedError {
    case pythonMissing
    case scriptMissing
    case iTermNotRunning
    case noSnapshot
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "iTerm2's Python runtime was not found. Open iTerm2 and enable Settings > General > Magic > Python API."
        case .scriptMissing:
            return "The iTerm2 workspace script is missing. Run Set Up or Repair Integrations."
        case .iTermNotRunning:
            return "iTerm2 is not running, so there is no layout to save."
        case .noSnapshot:
            return "No saved iTerm layout yet. Use Save iTerm Layout first."
        case .failed(let message):
            return message
        }
    }
}

/// Runs the bundled iterm2-workspace.py script to save or relaunch the whole
/// iTerm2 window/tab/split layout together with each pane's directory and
/// foreground command.
actor ITermWorkspaceRunner {
    static let shared = ITermWorkspaceRunner()

    private let snapshotPath = NSString(
        string: "~/Library/Application Support/Noturcode/iterm-workspace.json"
    ).expandingTildeInPath

    func snapshot() throws -> ITermWorkspaceSummary {
        guard isITermRunning() else { throw ITermWorkspaceError.iTermNotRunning }
        return try run(mode: "snapshot", timeout: 90)
    }

    func restore() throws -> ITermWorkspaceSummary {
        guard FileManager.default.fileExists(atPath: snapshotPath) else {
            throw ITermWorkspaceError.noSnapshot
        }
        // Launches iTerm2 when needed; the script retries until its API is up.
        _ = try? BoundedProcessRunner.run(
            executable: "/usr/bin/open", arguments: ["-a", "iTerm"], timeout: 10
        )
        return try run(mode: "restore", timeout: 240)
    }

    private func isITermRunning() -> Bool {
        let check = try? BoundedProcessRunner.run(
            executable: "/usr/bin/pgrep", arguments: ["-x", "iTerm2"], timeout: 5
        )
        return check?.status == 0
    }

    private func run(mode: String, timeout: TimeInterval) throws -> ITermWorkspaceSummary {
        guard let python = pythonExecutable() else { throw ITermWorkspaceError.pythonMissing }
        guard let script = scriptPath() else { throw ITermWorkspaceError.scriptMissing }
        let result: BoundedProcessResult
        do {
            result = try BoundedProcessRunner.run(
                executable: python,
                arguments: [script, mode, snapshotPath],
                timeout: timeout
            )
        } catch BoundedProcessRunnerError.timedOut {
            throw ITermWorkspaceError.failed("The iTerm2 \(mode) timed out.")
        }
        let stderr = String(decoding: result.error, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            let reason = stderr.components(separatedBy: .newlines).last(where: { !$0.isEmpty })
            throw ITermWorkspaceError.failed(reason ?? "The iTerm2 \(mode) failed.")
        }
        let stdout = String(decoding: result.output, as: UTF8.self)
        guard let data = stdout.data(using: .utf8),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data),
              let windows = counts["windows"], let panes = counts["panes"] else {
            throw ITermWorkspaceError.failed("The iTerm2 \(mode) returned an unreadable result.")
        }
        return ITermWorkspaceSummary(windows: windows, panes: panes)
    }

    private func scriptPath() -> String? {
        let fileManager = FileManager.default
        let installed = NSString(
            string: "~/Library/Application Support/Noturcode/bin/iterm2-workspace.py"
        ).expandingTildeInPath
        if fileManager.isExecutableFile(atPath: installed) { return installed }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("IntegrationPayload/integrations/iterm2-workspace.py").path,
           fileManager.fileExists(atPath: bundled) {
            return bundled
        }
        return nil
    }

    private func pythonExecutable() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let bases = [
            home + "/Library/Application Support/iTerm2/iterm2env/versions",
            home + "/.config/iterm2/AppSupport/iterm2env/versions"
        ]
        var best: (version: [Int], path: String)?
        for base in bases {
            for entry in (try? fileManager.contentsOfDirectory(atPath: base)) ?? [] {
                let path = base + "/" + entry + "/bin/python3"
                guard fileManager.isExecutableFile(atPath: path) else { continue }
                let version = entry.split(separator: ".").compactMap { Int($0) }
                if best == nil || best!.version.lexicographicallyPrecedes(version) {
                    best = (version, path)
                }
            }
        }
        return best?.path
    }
}
