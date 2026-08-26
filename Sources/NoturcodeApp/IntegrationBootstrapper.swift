import AppKit
import Foundation
import NoturcodeCore

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
        confirmation.informativeText = "Noturcode will install its local bridge, add hooks for detected coding harnesses, and enable live attach for future OpenSSH connections. Every file it replaces is backed up first. Your terminal sessions will not be restarted."
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
            let harnesses = discovery.filter { $0.kind == .harness && $0.detected }.map(\.id)
            let piFamilyExtension = try String(
                contentsOf: integrations.appendingPathComponent("noturcode-pi-extension.ts"),
                encoding: .utf8
            )
            for (source, destination) in [
                ("pi", home.appendingPathComponent(".pi/agent/extensions/noturcode.ts")),
                ("omp", home.appendingPathComponent(".omp/agent/extensions/noturcode.ts"))
            ] where harnesses.contains(source) {
                let materialized = piFamilyExtension.replacingOccurrences(
                    of: "__NOTURCODE_SOURCE__",
                    with: source
                )
                try writeIfChanged(
                    Data(materialized.utf8),
                    to: destination,
                    permissions: 0o644,
                    home: home,
                    backupDirectory: backup,
                    changed: &changed
                )
            }
            if harnesses.contains("hermes") {
                let source = integrations.appendingPathComponent(
                    "noturcode-hermes-plugin",
                    isDirectory: true
                )
                let destination = home.appendingPathComponent(
                    ".hermes/plugins/noturcode",
                    isDirectory: true
                )
                try replaceFile(
                    from: source.appendingPathComponent("plugin.yaml"),
                    to: destination.appendingPathComponent("plugin.yaml"),
                    permissions: 0o644,
                    home: home,
                    backupDirectory: backup,
                    changed: &changed
                )
                try replaceFile(
                    from: source.appendingPathComponent("__init__.py"),
                    to: destination.appendingPathComponent("__init__.py"),
                    permissions: 0o644,
                    home: home,
                    backupDirectory: backup,
                    changed: &changed
                )
                try enableHermesPlugin(
                    home: home,
                    backupDirectory: backup,
                    changed: &changed
                )
            }
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
                try removeLegacySummarySkill(at: destination, home: home,
                                             backupDirectory: backup, changed: &changed)
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
            let workspaceScript = support.appendingPathComponent("bin/iterm2-workspace.py")
            try replaceFile(
                from: integrations.appendingPathComponent("iterm2-workspace.py"),
                to: workspaceScript,
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
            case "pi": configured = fileManager.fileExists(atPath: home.appendingPathComponent(".pi/agent/extensions/noturcode.ts").path)
            case "omp": configured = fileManager.fileExists(atPath: home.appendingPathComponent(".omp/agent/extensions/noturcode.ts").path)
            case "hermes":
                configured = fileManager.fileExists(
                    atPath: home.appendingPathComponent(".hermes/plugins/noturcode/__init__.py").path
                ) && hermesPluginIsEnabled(home: home)
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
            ("gemini", "Gemini CLI"), ("pi", "Pi"), ("omp", "OMP"),
            ("hermes", "Hermes Agent"), ("opencode", "OpenCode")
        ]
        var result = executables.map { id, name in
            let dataDirectory: URL? = switch id {
            case "pi": home.appendingPathComponent(".pi/agent")
            case "omp": home.appendingPathComponent(".omp/agent")
            case "hermes": home.appendingPathComponent(".hermes/hermes-agent")
            default: nil
            }
            let detected = executableExists(id, home: home)
                || dataDirectory.map { fileManager.fileExists(atPath: $0.path) } == true
            return LocalIntegration(id: id, name: name, kind: .harness,
                                    detected: detected, configured: false)
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
        executableURL(name, home: home) != nil
    }

    private func executableURL(_ name: String, home: URL) -> URL? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                     home.appendingPathComponent(".local/bin").path,
                     home.appendingPathComponent(".bun/bin").path,
                     home.appendingPathComponent(".npm-global/bin").path]
        return paths.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func enableHermesPlugin(
        home: URL,
        backupDirectory: URL,
        changed: inout [String]
    ) throws {
        if hermesPluginIsEnabled(home: home) { return }
        guard let executable = executableURL("hermes", home: home) else {
            throw SetupError("Hermes Agent was detected, but its executable could not be found.")
        }
        let config = home.appendingPathComponent(".hermes/config.yaml")
        let before = try? Data(contentsOf: config)
        if before != nil {
            try backupExistingFile(config, home: home, backupDirectory: backupDirectory)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["HERMES_HOME"] = home.appendingPathComponent(".hermes").path
        let result = try BoundedProcessRunner.run(
            executable: executable.path,
            arguments: ["plugins", "enable", "noturcode", "--no-allow-tool-override"],
            environment: environment,
            timeout: 20
        )
        guard result.status == 0 else {
            let error = String(decoding: result.error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError(error.isEmpty ? "Hermes could not enable the Noturcode plugin." : error)
        }
        let after = try? Data(contentsOf: config)
        if before != after { changed.append(config.path) }
    }

    private func hermesPluginIsEnabled(home: URL) -> Bool {
        let config = home.appendingPathComponent(".hermes/config.yaml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        var pluginsIndent: Int?
        var enabledIndent: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if let pluginsIndent, indent <= pluginsIndent, trimmed != "plugins:" { break }
            if trimmed == "plugins:" {
                pluginsIndent = indent
                enabledIndent = nil
                continue
            }
            guard pluginsIndent != nil else { continue }
            if trimmed.hasPrefix("enabled:") {
                enabledIndent = indent
                let inline = trimmed.dropFirst("enabled:".count)
                if inline.contains("noturcode") { return true }
                continue
            }
            if let enabledIndent {
                if indent <= enabledIndent { break }
                let item = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if item == "noturcode" { return true }
            }
        }
        return false
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

    private func removeLegacySummarySkill(at destination: URL, home: URL,
                                          backupDirectory: URL, changed: inout [String]) throws {
        guard let content = try? String(contentsOf: destination, encoding: .utf8),
              content.contains("name: noturcode-summary"),
              content.contains("# Noturcode summary") else { return }
        try backupExistingFile(destination, home: home, backupDirectory: backupDirectory)
        try fileManager.removeItem(at: destination)
        changed.append(destination.path)
        try? fileManager.removeItem(at: destination.deletingLastPathComponent())
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
        const parents = new Map()
        const agentTypes = new Map()
        let deliveryQueue = Promise.resolve()
        const emit = (args) => {
          if (typeof Bun === "undefined") return Promise.resolve()
          deliveryQueue = deliveryQueue.then(async () => {
            try {
              const child = Bun.spawn([bridge, "emit", "--source", "opencode", ...args, "--pid", String(process.pid)], { stdout: "ignore", stderr: "ignore" })
              await child.exited
            } catch (_) {}
          }).catch(() => {})
          return deliveryQueue
        }
        const sessionID = (p) => p.session?.id || p.sessionID || p.sessionId || p.info?.sessionID || p.info?.id || p.id
        const reportedParent = (p) => p.session?.parentID || p.session?.parentId || p.session?.parent_id || p.info?.parentID || p.info?.parentId || p.info?.parent_id || p.parentID || p.parentId || p.parent_id
        const rootParent = (value) => {
          let current = value
          const seen = new Set()
          while (parents.has(current) && !seen.has(current)) { seen.add(current); current = parents.get(current) }
          return current
        }
        const childEvent = (type, parent, child, p) => {
          const agentType = p.session?.title || p.info?.title || p.agent || agentTypes.get(child) || "OpenCode agent"
          agentTypes.set(child, agentType)
          if (type === "session.created") emit(["--session", parent, "--kind", "subagentStarted", "--subagent", child, "--subagent-type", agentType])
          if (type === "session.updated" || type === "session.status") emit(["--session", parent, "--kind", "subagentActivity", "--subagent", child, "--subagent-type", agentType, "--activity", p.status?.message || p.status?.type || "working"])
          if (type === "session.idle" || type === "session.deleted") emit(["--session", parent, "--kind", "subagentCompleted", "--subagent", child, "--subagent-type", agentType])
          if (type === "session.error") emit(["--session", parent, "--kind", "subagentFailed", "--subagent", child, "--subagent-type", agentType, "--error", String(p.error?.message || p.error || "OpenCode agent failed")])
          if (type === "session.deleted") { parents.delete(child); agentTypes.delete(child) }
        }
        export const Noturcode = async () => ({
          event: async ({ event }) => {
            const p = event?.properties || {}
            const s = sessionID(p)
            if (!s) return
            const directParent = reportedParent(p)
            if (directParent) parents.set(s, rootParent(directParent))
            const parent = parents.get(s)
            if (parent) {
              childEvent(event.type, parent, s, p)
              return
            }
            const model = p.model || p.info?.model
            const providerID = model?.providerID || p.providerID || p.info?.providerID
            const modelID = model?.modelID || p.modelID || p.info?.modelID
            const agent = p.agent || p.info?.agent
            if (event.type === "session.created" || event.type === "session.updated") emit(["--session", s, "--kind", "connect", "--name", p.session?.title || p.info?.title || "OpenCode"])
            if ((event.type === "session.next.model.switched" || event.type === "message.updated") && (providerID || modelID || agent)) emit(["--session", s, "--kind", "metadataUpdated", ...(providerID ? ["--provider", providerID] : []), ...(modelID ? ["--model", modelID] : []), ...(agent ? ["--agent-role", agent] : [])])
            if (event.type === "session.next.agent.switched" && agent) emit(["--session", s, "--kind", "metadataUpdated", "--agent-role", agent])
            if (event.type === "session.idle") emit(["--session", s, "--kind", "turnInterrupted"])
            if (event.type === "session.error") emit(["--session", s, "--kind", "failed", "--error", String(p.error?.message || p.error || "OpenCode error")])
            if (event.type === "session.deleted") emit(["--session", s, "--kind", "disconnect"])
          },
          "tool.execute.before": async (input) => {
            const parent = parents.get(input.sessionID)
            if (parent) emit(["--session", parent, "--kind", "subagentActivity", "--subagent", input.sessionID, "--subagent-type", agentTypes.get(input.sessionID) || "OpenCode agent", "--activity", input.tool || "Tool"])
            else emit(["--session", input.sessionID, "--kind", "activityStarted", "--activity", input.tool || "Tool"])
          },
          "tool.execute.after": async (input) => {
            const parent = parents.get(input.sessionID)
            if (parent) emit(["--session", parent, "--kind", "subagentActivity", "--subagent", input.sessionID, "--subagent-type", agentTypes.get(input.sessionID) || "OpenCode agent", "--activity", input.tool || "Tool"])
            else emit(["--session", input.sessionID, "--kind", "activityFinished", "--activity", input.tool || "Tool"])
          }
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
