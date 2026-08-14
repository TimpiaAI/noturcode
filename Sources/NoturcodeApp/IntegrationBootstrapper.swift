import AppKit
import Foundation

struct LocalIntegration: Identifiable, Sendable {
    enum Kind: String, Sendable { case harness, terminal }

    let id: String
    let name: String
    let kind: Kind
    let detected: Bool
    let configured: Bool
}

struct IntegrationSetupReport: Sendable {
    let integrations: [LocalIntegration]
    let changedFiles: [String]
    let backupDirectory: String?
    let errors: [String]

    var isHealthy: Bool { errors.isEmpty }
}

@MainActor
final class IntegrationBootstrapper {
    static let shared = IntegrationBootstrapper()

    private let fileManager = FileManager.default
    private(set) var lastReport: IntegrationSetupReport?

    private init() {}

    func repairAndShowResult() {
        let confirmation = NSAlert()
        confirmation.messageText = "Set up Noturcode integrations?"
        confirmation.informativeText = "Noturcode will install its local bridge and add hooks for detected coding harnesses. Every file it replaces is backed up first. Your terminal sessions will not be restarted."
        confirmation.addButton(withTitle: "Set Up")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let report = install(home: fileManager.homeDirectoryForCurrentUser, payload: payloadURL)
        lastReport = report
        let alert = NSAlert()
        alert.messageText = report.isHealthy ? "Noturcode integrations are ready" : "Noturcode needs attention"
        let detected = report.integrations.filter(\.detected).map(\.name).joined(separator: ", ")
        if report.isHealthy {
            alert.informativeText = detected.isEmpty
                ? "The bridge is installed. No supported CLI harness was detected yet."
                : "Configured: \(detected). Existing terminal sessions were not touched."
        } else {
            alert.informativeText = report.errors.joined(separator: "\n")
        }
        alert.runModal()
    }

    private var payloadURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("IntegrationPayload", isDirectory: true)
    }

    func install(home: URL, payload: URL?) -> IntegrationSetupReport {
        var errors: [String] = []
        var changed: [String] = []
        let support = home.appendingPathComponent("Library/Application Support/Noturcode", isDirectory: true)
        let bridge = support.appendingPathComponent("bin/noturcode-bridge")
        let backup = support.appendingPathComponent("config-backups/\(Self.timestamp())", isDirectory: true)
        let discovery = discover(home: home)

        guard let payload else {
            return IntegrationSetupReport(integrations: discovery, changedFiles: [], backupDirectory: nil,
                                          errors: ["The app bundle is missing its integration payload."])
        }

        do {
            try fileManager.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bundledBridge = payload.appendingPathComponent("bin/noturcode-bridge")
            guard fileManager.isExecutableFile(atPath: bundledBridge.path) else {
                throw SetupError("The bundled Noturcode bridge is missing or not executable.")
            }
            try replaceFile(from: bundledBridge, to: bridge, permissions: 0o755,
                            home: home, backupDirectory: backup, changed: &changed)

            let integrations = payload.appendingPathComponent("integrations", isDirectory: true)
            try installSkill(
                from: integrations.appendingPathComponent("claude-nc-skill.md"),
                to: home.appendingPathComponent(".claude/skills/nc/SKILL.md"),
                home: home,
                backupDirectory: backup,
                changed: &changed
            )
            for destination in [
                home.appendingPathComponent(".claude/skills/noturcode-summary/SKILL.md"),
                home.appendingPathComponent(".codex/skills/noturcode-summary/SKILL.md")
            ] {
                try installSkill(from: integrations.appendingPathComponent("noturcode-summary-skill.md"),
                                 to: destination, home: home, backupDirectory: backup, changed: &changed)
            }
            let iTermScript = home.appendingPathComponent(
                "Library/Application Support/iTerm2/Scripts/AutoLaunch/Ask Noturcode.py"
            )
            try replaceFile(
                from: integrations.appendingPathComponent("iterm2-ask-noturcode.py"),
                to: iTermScript,
                permissions: 0o755,
                home: home,
                backupDirectory: backup,
                changed: &changed
            )
            let cli = support.appendingPathComponent("bin/noturcode-cli")
            try replaceFile(
                from: integrations.appendingPathComponent("noturcode-cli.zsh"),
                to: cli,
                permissions: 0o755,
                home: home,
                backupDirectory: backup,
                changed: &changed
            )
            let remoteAgent = support.appendingPathComponent("remote/noturcode-agent.py")
            try replaceFile(
                from: integrations.appendingPathComponent("noturcode-agent.py"),
                to: remoteAgent,
                permissions: 0o755,
                home: home,
                backupDirectory: backup,
                changed: &changed
            )
            let shellIntegration = home.appendingPathComponent(".config/noturcode/shell.zsh")
            try replaceFile(
                from: integrations.appendingPathComponent("noturcode-shell.zsh"),
                to: shellIntegration,
                permissions: 0o600,
                home: home,
                backupDirectory: backup,
                changed: &changed
            )
            try installZshSource(
                home: home,
                shellIntegration: shellIntegration,
                backupDirectory: backup,
                changed: &changed
            )

            let harnesses = discovery.filter { $0.kind == .harness && $0.detected }.map(\.id)
            if harnesses.contains("claude") {
                try mergeHooks(target: home.appendingPathComponent(".claude/settings.json"),
                               fragment: integrations.appendingPathComponent("claude-hooks.fragment.json"),
                               command: quotedCommand(bridge, source: "claude"), home: home,
                               backupDirectory: backup, changed: &changed)
            }
            if harnesses.contains("codex") {
                try mergeHooks(target: home.appendingPathComponent(".codex/hooks.json"),
                               fragment: integrations.appendingPathComponent("codex-hooks.fragment.json"),
                               command: quotedCommand(bridge, source: "codex"), home: home,
                               backupDirectory: backup, changed: &changed)
            }
            if harnesses.contains("gemini") {
                try mergeHooks(target: home.appendingPathComponent(".gemini/settings.json"),
                               fragment: integrations.appendingPathComponent("gemini-hooks.fragment.json"),
                               command: quotedCommand(bridge, source: "gemini"), home: home,
                               backupDirectory: backup, changed: &changed)
            }
            if harnesses.contains("opencode") {
                let plugin = home.appendingPathComponent(".config/opencode/plugins/noturcode.js")
                try writeIfChanged(Data(openCodePlugin(bridge: bridge).utf8), to: plugin, permissions: 0o644,
                                   home: home, backupDirectory: backup, changed: &changed)
            }
        } catch {
            errors.append(error.localizedDescription)
        }

        let refreshed = discover(home: home).map { item in
            guard item.kind == .harness, item.detected else { return item }
            let configured: Bool
            switch item.id {
            case "claude": configured = containsBridge(home.appendingPathComponent(".claude/settings.json"))
            case "codex": configured = containsBridge(home.appendingPathComponent(".codex/hooks.json"))
            case "gemini": configured = containsBridge(home.appendingPathComponent(".gemini/settings.json"))
            case "opencode": configured = fileManager.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/noturcode.js").path)
            default: configured = false
            }
            return LocalIntegration(id: item.id, name: item.name, kind: item.kind,
                                    detected: item.detected, configured: configured)
        }
        let backupPath = fileManager.fileExists(atPath: backup.path) ? backup.path : nil
        return IntegrationSetupReport(integrations: refreshed, changedFiles: changed,
                                      backupDirectory: backupPath, errors: errors)
    }

    func discover(home: URL) -> [LocalIntegration] {
        let executables = [
            ("claude", "Claude Code"), ("codex", "OpenAI Codex"),
            ("gemini", "Gemini CLI"), ("opencode", "OpenCode")
        ]
        var result = executables.map { id, name in
            LocalIntegration(id: id, name: name, kind: .harness,
                             detected: executableExists(id, home: home), configured: false)
        }
        let terminals = [
            ("terminal", "Apple Terminal", "/System/Applications/Utilities/Terminal.app"),
            ("iterm", "iTerm2", "/Applications/iTerm.app"),
            ("ghostty", "Ghostty", "/Applications/Ghostty.app"),
            ("warp", "Warp", "/Applications/Warp.app"),
            ("wezterm", "WezTerm", "/Applications/WezTerm.app"),
            ("kitty", "kitty", "/Applications/kitty.app")
        ]
        result += terminals.map { id, name, path in
            let detected = fileManager.fileExists(atPath: path)
            return LocalIntegration(id: id, name: name, kind: .terminal,
                                    detected: detected, configured: detected && id == "iterm")
        }
        return result
    }

    private func executableExists(_ name: String, home: URL) -> Bool {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                     home.appendingPathComponent(".local/bin").path,
                     home.appendingPathComponent(".bun/bin").path,
                     home.appendingPathComponent(".npm-global/bin").path]
        return paths.contains { fileManager.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(name).path) }
    }

    private func mergeHooks(target: URL, fragment: URL, command: String, home: URL,
                            backupDirectory: URL, changed: inout [String]) throws {
        var root = try jsonObject(at: target) ?? [:]
        guard let addition = try jsonObject(at: fragment),
              let fragmentHooks = addition["hooks"] as? [String: Any] else {
            throw SetupError("Invalid hook payload: \(fragment.lastPathComponent)")
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, rawGroups) in fragmentHooks {
            guard let groups = rawGroups as? [[String: Any]] else { continue }
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll(where: Self.containsNoturcodeCommand)
            existing.append(contentsOf: groups.map { Self.materialize($0, command: command) })
            hooks[event] = existing
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        if let current = try? Data(contentsOf: target), current == data { return }
        try writeIfChanged(data, to: target, permissions: 0o600,
                           home: home,
                           backupDirectory: backupDirectory, changed: &changed)
    }

    private static func containsNoturcodeCommand(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains("noturcode-bridge") == true }
    }

    private static func materialize(_ group: [String: Any], command: String) -> [String: Any] {
        var result = group
        if var hooks = result["hooks"] as? [[String: Any]] {
            hooks = hooks.map { hook in
                var value = hook
                if value["type"] as? String == "command" { value["command"] = command }
                return value
            }
            result["hooks"] = hooks
        }
        return result
    }

    private func jsonObject(at url: URL) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = value as? [String: Any] else { throw SetupError("Invalid JSON: \(url.path)") }
        return dictionary
    }

    private func installSkill(from source: URL, to destination: URL, home: URL,
                              backupDirectory: URL, changed: inout [String]) throws {
        try replaceFile(from: source, to: destination, permissions: 0o644,
                        home: home, backupDirectory: backupDirectory, changed: &changed)
    }

    private func installZshSource(home: URL, shellIntegration: URL, backupDirectory: URL,
                                  changed: inout [String]) throws {
        let profile = home.appendingPathComponent(".zshrc")
        let marker = "# Noturcode interactive CLI"
        let sourceLine = "[[ -r \"$HOME/.config/noturcode/shell.zsh\" ]] && source \"$HOME/.config/noturcode/shell.zsh\""
        let existing = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
        guard !existing.contains(sourceLine) else { return }
        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        updated += "\n\(marker)\n\(sourceLine)\n"
        try writeIfChanged(Data(updated.utf8), to: profile, permissions: 0o600,
                           home: home, backupDirectory: backupDirectory, changed: &changed)
    }

    private func replaceFile(from source: URL, to destination: URL, permissions: Int, home: URL,
                             backupDirectory: URL, changed: inout [String]) throws {
        let data = try Data(contentsOf: source)
        try writeIfChanged(data, to: destination, permissions: permissions,
                           home: home, backupDirectory: backupDirectory, changed: &changed)
    }

    private func writeIfChanged(_ data: Data, to destination: URL, permissions: Int, home: URL,
                                backupDirectory: URL, changed: inout [String]) throws {
        if let current = try? Data(contentsOf: destination), current == data { return }
        try backupExistingFile(destination, home: home, backupDirectory: backupDirectory)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        changed.append(destination.path)
    }

    private func backupExistingFile(_ destination: URL, home: URL, backupDirectory: URL) throws {
        guard fileManager.fileExists(atPath: destination.path) else { return }
        let homePath = home.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath.hasPrefix(homePath + "/") else {
            throw SetupError("Refusing to back up a file outside the user home: \(destinationPath)")
        }
        let relativePath = String(destinationPath.dropFirst(homePath.count + 1))
        let backupFile = backupDirectory.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: backupFile.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.copyItem(at: destination, to: backupFile)
    }

    private func containsBridge(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8).contains("noturcode-bridge")) == true
    }

    private func quotedCommand(_ bridge: URL, source: String) -> String {
        "\"\(bridge.path.replacingOccurrences(of: "\\\"", with: "\\\\\\\""))\" hook --source \(source)"
    }

    private func openCodePlugin(bridge: URL) -> String {
        let path = bridge.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        // Generated by Noturcode. Safe to regenerate from the app's Repair Integrations command.
        const bridge = "\(path)"
        const emit = (args) => {
          if (typeof Bun === "undefined") return
          try { Bun.spawn([bridge, "emit", "--source", "opencode", ...args], { stdout: "ignore", stderr: "ignore" }) } catch (_) {}
        }
        export const Noturcode = async () => ({
          event: async ({ event }) => {
            const p = event?.properties || {}
            const s = p.session?.id || p.sessionID || p.sessionId || p.id
            if (!s) return
            if (event.type === "session.created") emit(["--session", s, "--kind", "connect", "--name", p.session?.title || "OpenCode"])
            if (event.type === "session.idle") emit(["--session", s, "--kind", "responseCompleted"])
            if (event.type === "session.error") emit(["--session", s, "--kind", "failed", "--error", String(p.error?.message || p.error || "OpenCode error")])
            if (event.type === "session.deleted") emit(["--session", s, "--kind", "disconnect"])
          },
          "tool.execute.before": async (input) => emit(["--session", input.sessionID, "--kind", "activityStarted", "--activity", input.tool || "Tool"]),
          "tool.execute.after": async (input) => emit(["--session", input.sessionID, "--kind", "activityFinished", "--activity", input.tool || "Tool"])
        })
        """
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(8))
    }
}

private struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
