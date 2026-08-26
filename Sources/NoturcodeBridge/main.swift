import Darwin
import Foundation
import NoturcodeCore

struct NoturcodeBridgeMain {
    private enum DeliveryError: LocalizedError {
        case automaticLaunchPaused

        var errorDescription: String? {
            "Noturcode was quit and automatic launch is paused. Open Noturcode to resume."
        }
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            writeStandardOutput("Noturcode bridge\n")
            return
        }

        switch command {
        case "hook":
            runHook(arguments: Array(arguments.dropFirst()))
        case "emit":
            runEmit(arguments: Array(arguments.dropFirst()))
        case "doctor":
            runDoctor()
        case "pair-code":
            runPairCode(arguments: Array(arguments.dropFirst()))
        case "terminal-id":
            runTerminalID(arguments: Array(arguments.dropFirst()))
        case "socket-path":
            writeStandardOutput(NoturcodeSocket.path + "\n")
        case "ask-selection":
            runAskSelection(arguments: Array(arguments.dropFirst()))
        case "paste-image":
            runPasteImage(arguments: Array(arguments.dropFirst()))
        case "remote-terminal":
            runRemoteTerminal(arguments: Array(arguments.dropFirst()))
        default:
            writeStandardError("Unknown command: \(command)\n")
            Foundation.exit(64)
        }
    }

    private static func runHook(arguments: [String]) {
        if NoturcodeLaunchPolicy.isAutomaticLaunchPaused() {
            writeJSON([:])
            return
        }
        guard let sourceValue = option("--source", in: arguments),
              let source = AgentSource(rawValue: sourceValue) else {
            writeJSON(["decision": "block", "reason": "Noturcode hook is missing a valid source."])
            return
        }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        let processID = ProcessAncestry.agentProcessID()
        do {
            let payload = try JSONDecoder().decode(JSONValue.self, from: input)
            var result = HookNormalizer.normalize(
                payload: payload,
                source: source,
                environment: ProcessInfo.processInfo.environment,
                sourceProcessID: processID,
                now: Date()
            )
            let key = result.events.first?.key
            let existingSession = key.flatMap { key in
                SessionPersistence().load().first(where: { $0.key == key })
            }
            let eventName = payload.firstString(for: ["hook_event_name", "hookEventName", "type"]) ?? ""
            let transcriptPath = payload.firstString(for: ["transcript_path", "transcriptPath"])
            let checkpointStore = TokenUsageCheckpointStore()
            if let key, let transcriptPath,
               eventName.caseInsensitiveCompare("UserPromptSubmit") == .orderedSame {
                checkpointStore.mark(key, transcriptPath: transcriptPath, total: existingSession?.tokens ?? 0)
            }

            if let key, let transcriptPath,
               eventName.caseInsensitiveCompare("Stop") == .orderedSame {
                let sessionTokens: Int?
                switch source {
                case .claude:
                    if let checkpoint = checkpointStore.checkpoint(for: key),
                       checkpoint.transcriptPath == transcriptPath,
                       let delta = TranscriptTokenCounter.count(
                           source: .claude,
                           path: transcriptPath,
                           fromOffset: checkpoint.offset
                       ) {
                        sessionTokens = checkpoint.total + delta
                        checkpointStore.advance(key, transcriptPath: transcriptPath, total: sessionTokens ?? checkpoint.total)
                    } else {
                        checkpointStore.mark(key, transcriptPath: transcriptPath, total: existingSession?.tokens ?? 0)
                        sessionTokens = existingSession?.tokens
                    }
                case .codex:
                    sessionTokens = TranscriptTokenCounter.count(source: .codex, path: transcriptPath)
                case .gemini, .pi, .omp, .hermes, .opencode, .grok, .harness:
                    sessionTokens = existingSession?.tokens
                }
                if let sessionTokens {
                    for index in result.events.indices {
                        result.events[index].sessionTokens = sessionTokens
                    }
                }
            }

            var deliveryError: Error?
            for event in result.events {
                do {
                    try send(event: event, launchIfNeeded: true)
                } catch {
                    deliveryError = error
                }
            }

            if let key, result.events.contains(where: { $0.kind == .disconnect || $0.kind == .sessionEnded }) {
                checkpointStore.remove(key)
            }

            if var commandResult = result.commandResult {
                if let deliveryError, !result.events.isEmpty {
                    commandResult.message = "Noturcode could not receive this command: \(deliveryError.localizedDescription)"
                }
                if commandResult.shouldBlockPrompt {
                    writeJSON(["decision": "block", "reason": commandResult.message])
                } else {
                    writeJSON([
                        "hookSpecificOutput": [
                            "hookEventName": "UserPromptSubmit",
                            "additionalContext": commandResult.message
                        ]
                    ])
                }
            } else {
                writeJSON([:])
            }
        } catch {
            writeJSON([:])
        }
    }

    private static func runEmit(arguments: [String]) {
        if NoturcodeLaunchPolicy.isAutomaticLaunchPaused() {
            writeStandardOutput("paused\n")
            return
        }
        guard let sourceValue = option("--source", in: arguments),
              let source = AgentSource(rawValue: sourceValue),
              let sessionID = option("--session", in: arguments),
              let kindValue = option("--kind", in: arguments),
              let kind = BridgeEventKind(rawValue: kindValue) else {
            writeStandardError("emit requires --source, --session, and --kind\n")
            Foundation.exit(64)
        }
        if source == .opencode,
           kind.rawValue == BridgeEventKind.connect.rawValue,
           isOpenCodeChildSession(sessionID) {
            writeStandardOutput("ok\n")
            return
        }

        let event = BridgeEvent(
            kind: kind,
            source: source,
            sessionID: sessionID,
            name: option("--name", in: arguments),
            terminalSessionID: option("--terminal", in: arguments) ?? terminalIdentity(),
            sourceProcessID: option("--pid", in: arguments).flatMap(Int32.init),
            cwd: option("--cwd", in: arguments),
            transcriptPath: option("--transcript", in: arguments),
            provider: option("--provider", in: arguments),
            model: option("--model", in: arguments),
            theme: option("--theme", in: arguments),
            agentRole: option("--agent-role", in: arguments),
            message: option("--message", in: arguments),
            activity: option("--activity", in: arguments),
            error: option("--error", in: arguments),
            subagentID: option("--subagent", in: arguments),
            subagentType: option("--subagent-type", in: arguments),
            tokens: option("--tokens", in: arguments).flatMap(Int.init),
            sessionTokens: option("--session-tokens", in: arguments).flatMap(Int.init)
        )

        do {
            try send(event: event, launchIfNeeded: true)
            writeStandardOutput("ok\n")
        } catch {
            writeStandardError("\(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }

    private static func runDoctor() {
        let socketStatus: String
        do {
            _ = try UnixSocketClient.send(Data("{}".utf8))
            socketStatus = "listening"
        } catch {
            socketStatus = FileManager.default.fileExists(atPath: NoturcodeSocket.path) ? "stale" : "missing"
        }
        let appPath = findAppPath()
        let automaticLaunchStatus = NoturcodeLaunchPolicy.isAutomaticLaunchPaused() ? "paused" : "enabled"
        writeStandardOutput("socket: \(socketStatus)\n")
        writeStandardOutput("app: \(appPath ?? "not found")\n")
        writeStandardOutput("automatic-launch: \(automaticLaunchStatus)\n")
        let environment = ProcessInfo.processInfo.environment
        let identity = TerminalIdentity.capture(environment: environment, sourceProcessID: ProcessAncestry.agentProcessID())
        let terminal = identity?.application.displayName ?? "generic"
        let multiplexer = identity?.multiplexer.map { " (\($0.rawValue))" } ?? ""
        writeStandardOutput("terminal: \(terminal)\(multiplexer)\n")
    }

    private static func runPairCode(arguments: [String]) {
        let host = option("--host", in: arguments) ?? "remote VPS"
        do {
            let pairing = try RemotePairingStore().createCode(hostHint: host)
            writeStandardOutput(pairing.code + "\n")
        } catch {
            writeStandardError("Could not create a pairing code: \(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }

    private static func runTerminalID(arguments: [String]) {
        guard let identity = terminalIdentity(
            nativeSessionID: option("--native-session", in: arguments),
            remoteHost: option("--remote-host", in: arguments),
            sshControlPath: option("--ssh-control-path", in: arguments)
        ), !identity.isEmpty else {
            writeStandardError("Noturcode could not identify this terminal.\n")
            Foundation.exit(1)
        }
        writeStandardOutput(identity + "\n")
    }

    private static func runPasteImage(arguments: [String]) {
        guard let sessionID = option("--session", in: arguments), !sessionID.isEmpty else {
            writeStandardError("paste-image requires --session\n")
            Foundation.exit(64)
        }
        do {
            let request = TerminalImagePasteRequest(terminalSessionID: sessionID)
            try send(payload: JSONEncoder().encode(request), launchIfNeeded: false)
            writeStandardOutput("ok\n")
        } catch {
            writeStandardError("\(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }

    private static func runRemoteTerminal(arguments: [String]) {
        guard let action = arguments.first,
              let terminalSessionID = option("--terminal-id", in: arguments),
              !terminalSessionID.isEmpty else {
            writeStandardError("remote-terminal requires register or unregister and --terminal-id\n")
            Foundation.exit(64)
        }
        do {
            let registry = RemoteTerminalRegistry()
            switch action {
            case "register":
                try registry.register(terminalSessionID: terminalSessionID)
            case "unregister":
                try registry.unregister(terminalSessionID: terminalSessionID)
            default:
                writeStandardError("remote-terminal requires register or unregister\n")
                Foundation.exit(64)
            }
            writeStandardOutput("ok\n")
        } catch {
            writeStandardError("Could not \(action) the remote terminal: \(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }

    private static func runAskSelection(arguments: [String]) {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let selection = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else {
            writeStandardError("ask-selection requires selected text on stdin\n")
            Foundation.exit(64)
        }
        let request = SelectionContextRequest(
            selection: String(selection.prefix(20_000)),
            terminalSessionID: option("--session", in: arguments)
        )
        do {
            let payload = try JSONEncoder().encode(request)
            try send(payload: payload, launchIfNeeded: true)
            writeStandardOutput("ok\n")
        } catch {
            writeStandardError("\(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }

    private static func send(event: BridgeEvent, launchIfNeeded: Bool) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(BridgeEnvelope(event: event))
        try send(payload: data, launchIfNeeded: launchIfNeeded)
    }

    private static func send(payload data: Data, launchIfNeeded: Bool) throws {
        do {
            try sendAcknowledged(data)
            return
        } catch {
            if case UnixSocketError.responseTimeout = error { throw error }
            guard launchIfNeeded, let path = findAppPath() else { throw error }
            guard !NoturcodeLaunchPolicy.isAutomaticLaunchPaused() else {
                throw DeliveryError.automaticLaunchPaused
            }
            launchApp(at: path)
            var lastError: Error = error
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.05)
                do {
                    try sendAcknowledged(data)
                    return
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func sendAcknowledged(_ data: Data) throws {
        let response = try UnixSocketClient.send(data)
        guard responseAcknowledgesPersistence(response) else {
            throw UnixSocketError.responseTimeout
        }
    }

    private static func responseAcknowledgesPersistence(_ response: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let ok = object["ok"] as? Bool else { return false }
        return ok
    }

    private static func findAppPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            environment["NOTURCODE_APP_PATH"],
            "/Applications/Noturcode.app",
            "\(home)/Applications/Noturcode.app",
            "\(home)/noturcode/build/Debug/Noturcode.app"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func launchApp(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", path, "--args", "--background"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func terminalIdentity(
        nativeSessionID: String? = nil,
        remoteHost: String? = nil,
        sshControlPath: String? = nil
    ) -> String? {
        var environment = ProcessInfo.processInfo.environment
        if let nativeSessionID, !nativeSessionID.isEmpty {
            environment["TERM_PROGRAM"] = "iTerm.app"
            environment["TERM_SESSION_ID"] = nativeSessionID
        }
        if let remoteHost, !remoteHost.isEmpty {
            environment["NOTURCODE_REMOTE_HOST"] = remoteHost
        }
        if let sshControlPath, !sshControlPath.isEmpty {
            environment["NOTURCODE_SSH_CONTROL_PATH"] = sshControlPath
        }
        let parentPID = getppid()
        if environment["TTY"]?.isEmpty != false,
           let tty = ProcessAncestry.terminalTTY(pid: parentPID) {
            environment["TTY"] = tty
        }
        return TerminalIdentity.capture(environment: environment, sourceProcessID: parentPID)?.sessionID
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func isOpenCodeChildSession(_ sessionID: String) -> Bool {
        guard sessionID.range(of: #"^ses_[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
            return false
        }
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-noheader",
            database.path,
            "SELECT parent_id FROM session WHERE id = '\(sessionID)' AND parent_id IS NOT NULL LIMIT 1;"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
                && !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    private static func writeJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            writeStandardOutput("{}\n")
            return
        }
        writeStandardOutput(string + "\n")
    }

    private static func writeStandardOutput(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func writeStandardError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }
}

NoturcodeBridgeMain.main()
