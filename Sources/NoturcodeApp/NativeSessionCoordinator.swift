import Foundation
import NoturcodeCore

private enum ACPClientHandle: Sendable {
    case gemini(GeminiACPClient)
    case grok(GrokACPClient)

    func start() async throws {
        switch self {
        case let .gemini(client): try await client.start()
        case let .grok(client): try await client.start()
        }
    }

    func newSession(cwd: String) async throws -> String {
        switch self {
        case let .gemini(client): try await client.newSession(cwd: cwd)
        case let .grok(client): try await client.newSession(cwd: cwd)
        }
    }

    var supportsLoadSession: Bool {
        get async {
            switch self {
            case let .gemini(client): await client.supportsLoadSession
            case let .grok(client): await client.supportsLoadSession
            }
        }
    }

    func loadSession(sessionID: String, cwd: String) async throws {
        switch self {
        case let .gemini(client): try await client.loadSession(sessionID: sessionID, cwd: cwd)
        case let .grok(client): try await client.loadSession(sessionID: sessionID, cwd: cwd)
        }
    }

    func prompt(sessionID: String, text: String) async throws -> ACPPromptResult {
        switch self {
        case let .gemini(client): try await client.prompt(sessionID: sessionID, text: text)
        case let .grok(client): try await client.prompt(sessionID: sessionID, text: text)
        }
    }

    func respondToPermission(requestID: JSONValue, decision: ACPPermissionDecision) async throws {
        switch self {
        case let .gemini(client): try await client.respondToPermission(requestID: requestID, decision: decision)
        case let .grok(client): try await client.respondToPermission(requestID: requestID, decision: decision)
        }
    }

    func stop() async {
        switch self {
        case let .gemini(client): await client.stop()
        case let .grok(client): await client.stop()
        }
    }
}

actor NativeSessionCoordinator {
    typealias EventSink = @Sendable (BridgeEvent) async -> Void

    struct ApprovalOption: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let isDestructive: Bool
    }

    struct ApprovalQuestion: Identifiable, Equatable, Sendable {
        let id: String
        let header: String
        let prompt: String
        let options: [String]
        let allowsOther: Bool
        let isSecret: Bool
    }

    enum ApprovalKind: Equatable, Sendable {
        case codexDecision
        case codexPermissions(requested: JSONValue)
        case codexUserInput(questions: [ApprovalQuestion])
        case acp
        case openCode
    }

    enum ApprovalResponse: Equatable, Sendable {
        case option(String)
        case answers([String: [String]])
    }

    struct PendingApproval: Identifiable, Equatable, Sendable {
        var id: String { "\(sessionKey.description):\(String(describing: requestID))" }
        let sessionKey: SessionKey
        let requestID: JSONValue
        let method: String
        let title: String
        let detail: String?
        let kind: ApprovalKind
        let options: [ApprovalOption]
    }

    private struct PendingCodexContext: Sendable {
        let name: String
        let cwd: String
        let model: String?
    }

    private let eventSink: EventSink
    private var codexClients: [String: CodexAppServerClient] = [:]
    private var acpClients: [String: ACPClientHandle] = [:]
    private var openCodeClient: OpenCodeNativeClient?
    private var openCodeEndpoint: String?
    private var ignoredOpenCodeSessions: Set<String> = []
    private var clientTokensByThread: [String: String] = [:]
    private var acpTokensBySession: [SessionKey: String] = [:]
    private var contextsByClientToken: [String: PendingCodexContext] = [:]
    private var writers: [SessionKey: NativeTranscriptWriter] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]

    init(eventSink: @escaping EventSink) {
        self.eventSink = eventSink
    }

    func startCodexSession(name: String, cwd: String, model: String? = nil) async throws -> SessionKey {
        guard let codexURL = Self.executable(named: "codex") else {
            throw NativeSessionError.executableMissing("codex")
        }
        let clientToken = UUID().uuidString
        contextsByClientToken[clientToken] = PendingCodexContext(name: name, cwd: cwd, model: model)
        let client = CodexAppServerClient(codexURL: codexURL) { [weak self] event in
            await self?.handleCodex(event, clientToken: clientToken)
        }
        codexClients[clientToken] = client
        do {
            try await client.start()
            let threadID = try await client.startThread(cwd: cwd, model: model)
            let key = SessionKey(source: .codex, sessionID: threadID)
            await registerCodexThread(threadID, clientToken: clientToken, context: contextsByClientToken[clientToken])
            return key
        } catch {
            codexClients[clientToken] = nil
            contextsByClientToken[clientToken] = nil
            await client.stop()
            throw error
        }
    }

    func startACPSession(provider: ACPProvider, name: String, cwd: String) async throws -> SessionKey {
        let clientToken = UUID().uuidString
        let source: AgentSource = provider == .gemini ? .gemini : .grok
        contextsByClientToken[clientToken] = PendingCodexContext(name: name, cwd: cwd, model: nil)
        let handler: @Sendable (ACPEvent) async -> Void = { [weak self] event in
            await self?.handleACP(event, provider: provider, clientToken: clientToken)
        }
        let handle: ACPClientHandle
        switch provider {
        case .gemini:
            handle = .gemini(GeminiACPClient(eventHandler: handler))
        case .grok:
            handle = .grok(GrokACPClient(eventHandler: handler))
        }
        acpClients[clientToken] = handle
        do {
            try await handle.start()
            let sessionID = try await handle.newSession(cwd: cwd)
            let key = SessionKey(source: source, sessionID: sessionID)
            acpTokensBySession[key] = clientToken
            let writer = writer(for: key, model: nil)
            await eventSink(BridgeEvent(
                kind: .connect,
                source: source,
                sessionID: sessionID,
                name: name,
                nativeSession: NativeSessionConnection(transport: .acp, conversationID: sessionID),
                cwd: cwd,
                transcriptPath: writer.fileURL.path
            ))
            return key
        } catch {
            acpClients[clientToken] = nil
            contextsByClientToken[clientToken] = nil
            await handle.stop()
            throw error
        }
    }

    func startOpenCode(configuration: OpenCodeServerConfiguration) async throws {
        if let current = openCodeClient {
            await current.stop()
        }
        ignoredOpenCodeSessions.removeAll()
        let client = OpenCodeNativeClient(
            configuration: configuration,
            eventHandler: { [weak self] event in
                await self?.handleOpenCode(event)
            },
            chatHandler: { [weak self] sessionID, entries in
                await self?.handleOpenCodeChat(sessionID: sessionID, entries: entries)
            },
            permissionHandler: { [weak self] request in
                await self?.handleOpenCodePermission(request)
            }
        )
        openCodeClient = client
        openCodeEndpoint = configuration.baseURL.absoluteString
        do {
            try await client.start()
        } catch {
            openCodeClient = nil
            openCodeEndpoint = nil
            await client.stop()
            throw error
        }
    }

    func restore(_ sessions: [TrackedSession]) async {
        for session in sessions where session.nativeSession?.transport == .codexAppServer {
            do {
                _ = try await ensureCodexClient(for: session)
            } catch {
                await eventSink(BridgeEvent(
                    kind: .failed,
                    source: session.key.source,
                    sessionID: session.key.sessionID,
                    error: error.localizedDescription
                ))
            }
        }
        for session in sessions where session.nativeSession?.transport == .acp {
            do {
                try await restoreACPSession(session)
            } catch {
                await eventSink(BridgeEvent(
                    kind: .failed,
                    source: session.key.source,
                    sessionID: session.key.sessionID,
                    error: error.localizedDescription
                ))
            }
        }
        if openCodeClient == nil,
           let endpoint = sessions.compactMap({ session -> String? in
               guard session.nativeSession?.transport == .openCodeServer else { return nil }
               return session.nativeSession?.endpoint
           }).first,
           let url = URL(string: endpoint) {
            do {
                try await startOpenCode(configuration: OpenCodeServerConfiguration(baseURL: url))
            } catch {
                for session in sessions where session.nativeSession?.transport == .openCodeServer {
                    await eventSink(BridgeEvent(
                        kind: .failed,
                        source: .opencode,
                        sessionID: session.key.sessionID,
                        error: error.localizedDescription
                    ))
                }
            }
        }
    }

    private func restoreACPSession(_ session: TrackedSession) async throws {
        let provider: ACPProvider
        switch session.key.source {
        case .gemini: provider = .gemini
        case .grok: provider = .grok
        default: throw NativeSessionError.invalidACPProvider
        }

        let clientToken = UUID().uuidString
        let handler: @Sendable (ACPEvent) async -> Void = { [weak self] event in
            await self?.handleACP(event, provider: provider, clientToken: clientToken)
        }
        let handle: ACPClientHandle = switch provider {
        case .gemini: .gemini(GeminiACPClient(eventHandler: handler))
        case .grok: .grok(GrokACPClient(eventHandler: handler))
        }
        acpClients[clientToken] = handle
        contextsByClientToken[clientToken] = PendingCodexContext(
            name: session.name,
            cwd: session.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
            model: nil
        )
        do {
            try await handle.start()
            guard await handle.supportsLoadSession else { throw ACPClientError.loadSessionUnsupported }
            acpTokensBySession[session.key] = clientToken
            try await handle.loadSession(
                sessionID: session.key.sessionID,
                cwd: session.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            )
            let transcript = writer(for: session.key, model: nil)
            await eventSink(BridgeEvent(
                kind: .sessionStarted,
                source: session.key.source,
                sessionID: session.key.sessionID,
                name: session.name,
                nativeSession: NativeSessionConnection(
                    transport: .acp,
                    conversationID: session.key.sessionID
                ),
                cwd: session.cwd,
                transcriptPath: transcript.fileURL.path
            ))
        } catch {
            acpTokensBySession[session.key] = nil
            acpClients[clientToken] = nil
            contextsByClientToken[clientToken] = nil
            await handle.stop()
            throw error
        }
    }

    func send(_ prompt: String, imagePaths: [String], to session: TrackedSession) async -> ITermPromptResult {
        if session.nativeSession?.transport == .acp {
            return await sendACP(prompt, imagePaths: imagePaths, to: session)
        }
        if session.nativeSession?.transport == .openCodeServer {
            return await sendOpenCode(prompt, imagePaths: imagePaths, to: session)
        }
        guard session.nativeSession?.transport == .codexAppServer else {
            return .failed("This native session transport is not connected yet.")
        }
        do {
            let client = try await ensureCodexClient(for: session)
            let writer = writer(for: session.key, model: nil)
            await writer.appendUser(prompt, imagePaths: imagePaths)
            await eventSink(BridgeEvent(
                kind: .promptSubmitted,
                source: session.key.source,
                sessionID: session.key.sessionID,
                transcriptPath: writer.fileURL.path,
                prompt: prompt
            ))
            try await client.sendPrompt(
                threadID: session.key.sessionID,
                text: prompt,
                localImagePaths: imagePaths
            )
            return .sent
        } catch {
            await eventSink(BridgeEvent(
                kind: .failed,
                source: session.key.source,
                sessionID: session.key.sessionID,
                error: error.localizedDescription
            ))
            return .failed(error.localizedDescription)
        }
    }

    func compact(_ session: TrackedSession) async -> ITermPromptResult {
        await send("/compact", imagePaths: [], to: session)
    }

    func stop(session: TrackedSession) async {
        if session.nativeSession?.transport == .openCodeServer {
            ignoredOpenCodeSessions.insert(session.key.sessionID)
            pendingApprovals = pendingApprovals.filter { $0.value.sessionKey != session.key }
            return
        }
        if let token = acpTokensBySession.removeValue(forKey: session.key),
           let client = acpClients.removeValue(forKey: token) {
            contextsByClientToken[token] = nil
            pendingApprovals = pendingApprovals.filter { $0.value.sessionKey != session.key }
            await client.stop()
            return
        }
        guard let token = clientTokensByThread.removeValue(forKey: session.key.sessionID),
              let client = codexClients.removeValue(forKey: token) else { return }
        contextsByClientToken[token] = nil
        pendingApprovals = pendingApprovals.filter { $0.value.sessionKey != session.key }
        await client.stop()
    }

    func stopAll() async {
        let clients = Array(codexClients.values)
        let acp = Array(acpClients.values)
        let openCode = openCodeClient
        codexClients.removeAll()
        acpClients.removeAll()
        openCodeClient = nil
        openCodeEndpoint = nil
        ignoredOpenCodeSessions.removeAll()
        clientTokensByThread.removeAll()
        acpTokensBySession.removeAll()
        contextsByClientToken.removeAll()
        pendingApprovals.removeAll()
        for client in clients { await client.stop() }
        for client in acp { await client.stop() }
        await openCode?.stop()
    }

    func approvals(for key: SessionKey) -> [PendingApproval] {
        pendingApprovals.values.filter { $0.sessionKey == key }
    }

    func respond(to approval: PendingApproval, with response: ApprovalResponse) async throws {
        let key = approvalKey(threadID: approval.sessionKey.sessionID, requestID: approval.requestID)
        guard pendingApprovals[key] == approval else { throw NativeSessionError.approvalExpired }

        switch approval.kind {
        case .codexDecision:
            guard case let .option(decision) = response else { throw NativeSessionError.invalidApprovalResponse }
            let client = try codexClient(for: approval.sessionKey)
            try await client.respondToServerRequest(
                id: approval.requestID,
                result: .object(["decision": .string(decision)])
            )

        case let .codexPermissions(requested):
            guard case let .option(decision) = response else { throw NativeSessionError.invalidApprovalResponse }
            let client = try codexClient(for: approval.sessionKey)
            let result: JSONValue
            switch decision {
            case "accept":
                result = .object(["scope": .string("turn"), "permissions": requested])
            case "acceptForSession":
                result = .object(["scope": .string("session"), "permissions": requested])
            default:
                result = .object(["scope": .string("turn"), "permissions": .object([:])])
            }
            try await client.respondToServerRequest(id: approval.requestID, result: result)

        case let .codexUserInput(questions):
            guard case let .answers(answers) = response else { throw NativeSessionError.invalidApprovalResponse }
            guard questions.allSatisfy({ !(answers[$0.id] ?? []).isEmpty }) else {
                throw NativeSessionError.incompleteUserInput
            }
            let encoded = answers.reduce(into: [String: JSONValue]()) { result, pair in
                result[pair.key] = .object(["answers": .array(pair.value.map(JSONValue.string))])
            }
            let client = try codexClient(for: approval.sessionKey)
            try await client.respondToServerRequest(
                id: approval.requestID,
                result: .object(["answers": .object(encoded)])
            )

        case .acp:
            guard let token = acpTokensBySession[approval.sessionKey], let client = acpClients[token] else {
                throw NativeSessionError.nativeClientMissing
            }
            guard case let .option(optionID) = response else { throw NativeSessionError.invalidApprovalResponse }
            let decision: ACPPermissionDecision = optionID == "cancel"
                ? .cancelled
                : .selected(optionID: optionID)
            try await client.respondToPermission(requestID: approval.requestID, decision: decision)

        case .openCode:
            guard let client = openCodeClient,
                  case let .string(permissionID) = approval.requestID,
                  case let .option(rawReply) = response,
                  let reply = OpenCodePermissionReply(rawValue: rawReply) else {
                throw NativeSessionError.invalidApprovalResponse
            }
            try await client.respondToPermission(
                sessionID: approval.sessionKey.sessionID,
                permissionID: permissionID,
                reply: reply
            )
        }

        pendingApprovals.removeValue(forKey: key)
        await eventSink(BridgeEvent(
            kind: .activityStarted,
            source: approval.sessionKey.source,
            sessionID: approval.sessionKey.sessionID,
            activity: "resuming"
        ))
    }

    private func codexClient(for key: SessionKey) throws -> CodexAppServerClient {
        guard let token = clientTokensByThread[key.sessionID], let client = codexClients[token] else {
            throw NativeSessionError.nativeClientMissing
        }
        return client
    }

    private func ensureCodexClient(for session: TrackedSession) async throws -> CodexAppServerClient {
        if let token = clientTokensByThread[session.key.sessionID], let client = codexClients[token] {
            return client
        }
        guard let codexURL = Self.executable(named: "codex") else {
            throw NativeSessionError.executableMissing("codex")
        }
        let token = UUID().uuidString
        contextsByClientToken[token] = PendingCodexContext(
            name: session.name,
            cwd: session.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
            model: nil
        )
        let client = CodexAppServerClient(codexURL: codexURL) { [weak self] event in
            await self?.handleCodex(event, clientToken: token)
        }
        codexClients[token] = client
        do {
            try await client.start()
            try await client.resumeThread(session.key.sessionID)
            clientTokensByThread[session.key.sessionID] = token
            return client
        } catch {
            codexClients[token] = nil
            contextsByClientToken[token] = nil
            await client.stop()
            throw error
        }
    }

    private func sendACP(
        _ prompt: String,
        imagePaths: [String],
        to session: TrackedSession
    ) async -> ITermPromptResult {
        guard let token = acpTokensBySession[session.key], let client = acpClients[token] else {
            return .failed("This ACP session must be started again after Noturcode restarts.")
        }
        let writer = writer(for: session.key, model: nil)
        await writer.appendUser(prompt, imagePaths: imagePaths)
        await eventSink(BridgeEvent(
            kind: .promptSubmitted,
            source: session.key.source,
            sessionID: session.key.sessionID,
            transcriptPath: writer.fileURL.path,
            prompt: prompt
        ))
        Task { [weak self] in
            do {
                let result = try await client.prompt(sessionID: session.key.sessionID, text: prompt)
                await self?.finishACPPrompt(session: session, result: result)
            } catch {
                await self?.eventSink(BridgeEvent(
                    kind: .failed,
                    source: session.key.source,
                    sessionID: session.key.sessionID,
                    error: error.localizedDescription
                ))
            }
        }
        return .sent
    }

    private func sendOpenCode(
        _ prompt: String,
        imagePaths: [String],
        to session: TrackedSession
    ) async -> ITermPromptResult {
        guard let client = openCodeClient else {
            return .failed("Reconnect the OpenCode server from the New session menu.")
        }
        guard imagePaths.isEmpty else {
            return .failed("OpenCode image input is not available through the local server yet.")
        }
        do {
            ignoredOpenCodeSessions.remove(session.key.sessionID)
            try await client.sendPrompt(sessionID: session.key.sessionID, text: prompt)
            return .sent
        } catch {
            await eventSink(BridgeEvent(
                kind: .failed,
                source: .opencode,
                sessionID: session.key.sessionID,
                error: error.localizedDescription
            ))
            return .failed(error.localizedDescription)
        }
    }

    private func finishACPPrompt(session: TrackedSession, result: ACPPromptResult) async {
        let writer = writer(for: session.key, model: nil)
        await eventSink(BridgeEvent(
            kind: .responseCompleted,
            source: session.key.source,
            sessionID: session.key.sessionID,
            transcriptPath: writer.fileURL.path,
            message: await writer.latestAssistantText()
        ))
    }

    private func handleOpenCode(_ incoming: BridgeEvent) async {
        guard !ignoredOpenCodeSessions.contains(incoming.sessionID) else { return }
        var event = incoming
        let key = SessionKey(source: .opencode, sessionID: incoming.sessionID)
        let transcript = writer(for: key, model: nil)
        event.transcriptPath = transcript.fileURL.path
        if event.nativeSession == nil {
            event.nativeSession = NativeSessionConnection(
                transport: .openCodeServer,
                conversationID: incoming.sessionID,
                endpoint: openCodeEndpoint
            )
        }
        await eventSink(event)
    }

    private func handleOpenCodeChat(sessionID: String, entries: [ChatTranscriptEntry]) async {
        guard !ignoredOpenCodeSessions.contains(sessionID) else { return }
        let transcript = writer(for: SessionKey(source: .opencode, sessionID: sessionID), model: nil)
        await transcript.merge(entries)
    }

    private func handleOpenCodePermission(_ request: OpenCodePermissionRequest) async {
        guard !ignoredOpenCodeSessions.contains(request.sessionID) else { return }
        let requestID = JSONValue.string(request.id)
        let sessionKey = SessionKey(source: .opencode, sessionID: request.sessionID)
        pendingApprovals[approvalKey(threadID: request.sessionID, requestID: requestID)] = PendingApproval(
            sessionKey: sessionKey,
            requestID: requestID,
            method: "opencode/permission",
            title: request.title ?? request.type ?? "OpenCode permission",
            detail: request.pattern.isEmpty ? nil : request.pattern.joined(separator: "\n"),
            kind: .openCode,
            options: [
                ApprovalOption(id: "once", label: "Allow once", isDestructive: false),
                ApprovalOption(id: "always", label: "Always allow", isDestructive: false),
                ApprovalOption(id: "reject", label: "Reject", isDestructive: true)
            ]
        )
        await eventSink(BridgeEvent(
            kind: .askingYou,
            source: .opencode,
            sessionID: request.sessionID,
            transcriptPath: writer(for: sessionKey, model: nil).fileURL.path,
            activity: request.title ?? request.type ?? "Review permissions"
        ))
    }

    private func handleACP(_ event: ACPEvent, provider: ACPProvider, clientToken: String) async {
        let source: AgentSource = provider == .gemini ? .gemini : .grok
        func key(_ sessionID: String) -> SessionKey {
            SessionKey(source: source, sessionID: sessionID)
        }
        func emit(
            _ kind: BridgeEventKind,
            sessionID: String,
            activity: String? = nil,
            message: String? = nil,
            error: String? = nil,
            transcriptPath: String? = nil
        ) async {
            await eventSink(BridgeEvent(
                kind: kind,
                source: source,
                sessionID: sessionID,
                transcriptPath: transcriptPath,
                message: message,
                activity: activity,
                error: error
            ))
        }

        switch event {
        case .initialized:
            break

        case let .sessionUpdate(update):
            switch update {
            case let .stateUpdate(sessionID, state, _):
                guard !sessionID.isEmpty else { return }
                let normalized = state?.lowercased() ?? ""
                if ["idle", "done", "completed", "stopped"].contains(normalized) {
                    let transcript = writer(for: key(sessionID), model: nil)
                    await emit(
                        .responseCompleted,
                        sessionID: sessionID,
                        message: await transcript.latestAssistantText(),
                        transcriptPath: transcript.fileURL.path
                    )
                } else {
                    await emit(.activityStarted, sessionID: sessionID, activity: state ?? "thinking")
                }

            case let .userMessageChunk(sessionID, _):
                guard !sessionID.isEmpty else { return }
                await emit(.activityStarted, sessionID: sessionID, activity: "prompt received")

            case let .agentMessageChunk(sessionID, text, messageID):
                guard !sessionID.isEmpty, !text.isEmpty else { return }
                let transcript = writer(for: key(sessionID), model: nil)
                await transcript.appendAssistantDelta(text, itemID: messageID ?? "assistant-active")
                await emit(
                    .activityStarted,
                    sessionID: sessionID,
                    activity: "writing",
                    transcriptPath: transcript.fileURL.path
                )

            case let .agentThoughtChunk(sessionID, text):
                guard !sessionID.isEmpty, !text.isEmpty else { return }
                let transcript = writer(for: key(sessionID), model: nil)
                await transcript.upsertTool(
                    itemID: "thought-active",
                    title: "Thinking",
                    detail: text,
                    completed: false
                )

            case let .toolCall(sessionID, callID, title, status, raw):
                guard !sessionID.isEmpty else { return }
                let transcript = writer(for: key(sessionID), model: nil)
                await transcript.upsertTool(
                    itemID: callID ?? UUID().uuidString,
                    title: title ?? "Use tool",
                    detail: Self.jsonText(raw),
                    completed: Self.isCompleted(status)
                )
                await emit(
                    Self.isCompleted(status) ? .activityFinished : .activityStarted,
                    sessionID: sessionID,
                    activity: title ?? "Use tool",
                    transcriptPath: transcript.fileURL.path
                )

            case let .toolCallUpdate(sessionID, callID, status, raw):
                guard !sessionID.isEmpty else { return }
                let transcript = writer(for: key(sessionID), model: nil)
                await transcript.upsertTool(
                    itemID: callID ?? "tool-active",
                    title: "Use tool",
                    detail: Self.jsonText(raw),
                    completed: Self.isCompleted(status)
                )

            case let .plan(sessionID, text):
                guard !sessionID.isEmpty else { return }
                await writer(for: key(sessionID), model: nil).upsertTool(
                    itemID: "plan-active",
                    title: "Plan",
                    detail: text,
                    completed: false
                )

            case .unknown:
                break
            }

        case let .permissionRequested(request):
            let sessionKey = key(request.sessionID)
            pendingApprovals[approvalKey(threadID: request.sessionID, requestID: request.requestID)] = PendingApproval(
                sessionKey: sessionKey,
                requestID: request.requestID,
                method: "session/request_permission",
                title: request.title ?? "Permission request",
                detail: request.description,
                kind: .acp,
                options: request.options.map {
                    ApprovalOption(id: $0.optionID, label: $0.name ?? $0.optionID, isDestructive: false)
                } + [ApprovalOption(id: "cancel", label: "Reject", isDestructive: true)]
            )
            await emit(
                .askingYou,
                sessionID: request.sessionID,
                activity: request.title ?? request.description ?? "Review permissions"
            )

        case let .malformed(message):
            let matchingSession = acpTokensBySession.first(where: { $0.value == clientToken })?.key
            if let matchingSession {
                await emit(.failed, sessionID: matchingSession.sessionID, error: message)
            }

        case .serverRequest, .notification:
            break
        }
    }

    private func registerCodexThread(
        _ threadID: String,
        clientToken: String,
        context: PendingCodexContext?
    ) async {
        guard clientTokensByThread[threadID] == nil else { return }
        clientTokensByThread[threadID] = clientToken
        let context = context ?? PendingCodexContext(
            name: "Codex",
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            model: nil
        )
        let writer = writer(for: SessionKey(source: .codex, sessionID: threadID), model: context.model)
        await eventSink(BridgeEvent(
            kind: .connect,
            source: .codex,
            sessionID: threadID,
            name: context.name,
            nativeSession: NativeSessionConnection(
                transport: .codexAppServer,
                conversationID: threadID
            ),
            cwd: context.cwd,
            transcriptPath: writer.fileURL.path
        ))
    }

    private func handleCodex(_ event: CodexAppServerEvent, clientToken: String) async {
        switch event {
        case let .threadStarted(threadID, cwd, model):
            var context = contextsByClientToken[clientToken]
            if let cwd {
                context = PendingCodexContext(
                    name: context?.name ?? "Codex",
                    cwd: cwd,
                    model: model ?? context?.model
                )
                contextsByClientToken[clientToken] = context
            }
            await registerCodexThread(threadID, clientToken: clientToken, context: context)

        case let .turnStarted(threadID, _):
            await eventSink(bridgeEvent(.activityStarted, threadID: threadID, activity: "thinking"))

        case let .agentMessageDelta(threadID, _, itemID, delta):
            await writer(for: SessionKey(source: .codex, sessionID: threadID), model: nil)
                .appendAssistantDelta(delta, itemID: itemID)

        case let .activity(threadID, itemID, title, detail, completed):
            let writer = writer(for: SessionKey(source: .codex, sessionID: threadID), model: nil)
            await writer.upsertTool(itemID: itemID, title: title, detail: detail, completed: completed)
            await eventSink(bridgeEvent(
                completed ? .activityFinished : .activityStarted,
                threadID: threadID,
                activity: title,
                transcriptPath: writer.fileURL.path
            ))

        case let .askingYou(threadID, requestID, method, params):
            guard let threadID else { return }
            if let requestID {
                let approval = Self.codexApproval(
                    threadID: threadID,
                    requestID: requestID,
                    method: method,
                    params: params
                )
                pendingApprovals[approvalKey(threadID: threadID, requestID: requestID)] = approval
            }
            await eventSink(bridgeEvent(.askingYou, threadID: threadID, activity: Self.approvalLabel(method)))

        case let .turnCompleted(threadID, _, finalMessage):
            let writer = writer(for: SessionKey(source: .codex, sessionID: threadID), model: nil)
            if let finalMessage { await writer.finalizeAssistant(finalMessage) }
            await eventSink(bridgeEvent(
                .responseCompleted,
                threadID: threadID,
                message: finalMessage,
                transcriptPath: writer.fileURL.path
            ))

        case let .failed(threadID, message):
            guard let threadID else { return }
            await eventSink(bridgeEvent(.failed, threadID: threadID, error: message))
        }
    }

    private func writer(for key: SessionKey, model: String?) -> NativeTranscriptWriter {
        if let writer = writers[key] { return writer }
        let writer = NativeTranscriptWriter(key: key, model: model)
        writers[key] = writer
        return writer
    }

    private func bridgeEvent(
        _ kind: BridgeEventKind,
        threadID: String,
        activity: String? = nil,
        message: String? = nil,
        error: String? = nil,
        transcriptPath: String? = nil
    ) -> BridgeEvent {
        BridgeEvent(
            kind: kind,
            source: .codex,
            sessionID: threadID,
            transcriptPath: transcriptPath,
            message: message,
            activity: activity,
            error: error
        )
    }

    private func approvalKey(threadID: String, requestID: JSONValue) -> String {
        "\(threadID):\(String(describing: requestID))"
    }

    private static func approvalLabel(_ method: String) -> String {
        if method.contains("commandExecution") { return "Approve command" }
        if method.contains("fileChange") { return "Approve file changes" }
        if method.contains("requestUserInput") { return "Answer Codex" }
        return "Review permissions"
    }

    private static func codexApproval(
        threadID: String,
        requestID: JSONValue,
        method: String,
        params: JSONValue
    ) -> PendingApproval {
        let sessionKey = SessionKey(source: .codex, sessionID: threadID)
        if method.contains("requestUserInput") {
            let questions = codexQuestions(params)
            return PendingApproval(
                sessionKey: sessionKey,
                requestID: requestID,
                method: method,
                title: questions.first?.header ?? "Codex needs your answer",
                detail: questions.first?.prompt,
                kind: .codexUserInput(questions: questions),
                options: []
            )
        }

        let detail = [
            params.firstString(for: ["reason"]),
            params.firstString(for: ["command"]),
            params.firstString(for: ["cwd"])
        ].compactMap { $0 }.joined(separator: "\n")
        if method.contains("permissions/requestApproval") {
            return PendingApproval(
                sessionKey: sessionKey,
                requestID: requestID,
                method: method,
                title: "Codex requests access",
                detail: detail.isEmpty ? nil : detail,
                kind: .codexPermissions(requested: params["permissions"] ?? .object([:])),
                options: decisionOptions
            )
        }
        return PendingApproval(
            sessionKey: sessionKey,
            requestID: requestID,
            method: method,
            title: approvalLabel(method),
            detail: detail.isEmpty ? nil : detail,
            kind: .codexDecision,
            options: decisionOptions
        )
    }

    private static let decisionOptions = [
        ApprovalOption(id: "accept", label: "Allow once", isDestructive: false),
        ApprovalOption(id: "acceptForSession", label: "Allow this session", isDestructive: false),
        ApprovalOption(id: "decline", label: "Reject", isDestructive: true)
    ]

    private static func codexQuestions(_ params: JSONValue) -> [ApprovalQuestion] {
        guard case let .array(values) = params["questions"] else { return [] }
        return values.compactMap { value in
            guard let id = value.firstString(for: ["id"]),
                  let prompt = value.firstString(for: ["question"]) else { return nil }
            let options: [String]
            if case let .array(rawOptions) = value["options"] {
                options = rawOptions.compactMap { $0.firstString(for: ["label"]) }
            } else {
                options = []
            }
            return ApprovalQuestion(
                id: id,
                header: value.firstString(for: ["header"]) ?? "Question",
                prompt: prompt,
                options: options,
                allowsOther: value["isOther"]?.boolValue ?? false,
                isSecret: value["isSecret"]?.boolValue ?? false
            )
        }
    }

    private static func isCompleted(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return ["done", "completed", "failed", "cancelled"].contains(status)
    }

    private static func jsonText(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func executable(named name: String) -> URL? {
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(name)").path
        ]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name).path }
        candidates.append(contentsOf: pathCandidates)
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}

enum NativeSessionError: Error, LocalizedError {
    case executableMissing(String)
    case approvalExpired
    case invalidApprovalResponse
    case incompleteUserInput
    case nativeClientMissing
    case invalidACPProvider

    var errorDescription: String? {
        switch self {
        case let .executableMissing(name): "Noturcode could not find the \(name) executable."
        case .approvalExpired: "This approval request is no longer active."
        case .invalidApprovalResponse: "The approval response is not valid for this request."
        case .incompleteUserInput: "Answer each question before you continue."
        case .nativeClientMissing: "The native agent connection is no longer active."
        case .invalidACPProvider: "This saved session is not a Gemini or Grok ACP session."
        }
    }
}

private actor NativeTranscriptWriter {
    struct Entry: Sendable {
        enum Kind: Equatable, Sendable { case system, user, assistant, tool }
        var id: String
        var kind: Kind
        var title: String?
        var text: String
        var detail: String?
        var imagePaths: [String]
        var timestamp: Date
    }

    let fileURL: URL
    private let model: String?
    private var entries: [Entry] = []
    private var flushTask: Task<Void, Never>?

    init(key: SessionKey, model: String?) {
        self.model = model
        let safeID = key.sessionID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = support
            .appendingPathComponent("Noturcode/native-transcripts", isDirectory: true)
            .appendingPathComponent("\(key.source.rawValue)-\(safeID).jsonl")
    }

    func appendUser(_ text: String, imagePaths: [String]) {
        entries.append(Entry(
            id: UUID().uuidString,
            kind: .user,
            text: text,
            imagePaths: imagePaths,
            timestamp: Date()
        ))
        scheduleFlush()
    }

    func merge(_ incoming: [ChatTranscriptEntry]) {
        for item in incoming {
            let kind: Entry.Kind = switch item.kind {
            case .system: .system
            case .user: .user
            case .assistant: .assistant
            case .tool: .tool
            }
            let entry = Entry(
                id: item.id,
                kind: kind,
                title: item.title,
                text: item.text,
                detail: item.detail,
                imagePaths: item.imagePaths,
                timestamp: item.timestamp ?? Date()
            )
            if let index = entries.firstIndex(where: { $0.id == item.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        entries.sort { $0.timestamp < $1.timestamp }
        scheduleFlush()
    }

    func appendAssistantDelta(_ delta: String, itemID: String) {
        if let index = entries.lastIndex(where: { $0.id == itemID && $0.kind == .assistant }) {
            entries[index].text.append(delta)
        } else {
            entries.append(Entry(
                id: itemID,
                kind: .assistant,
                text: delta,
                imagePaths: [],
                timestamp: Date()
            ))
        }
        scheduleFlush()
    }

    func finalizeAssistant(_ text: String) {
        if let index = entries.lastIndex(where: { $0.kind == .assistant }) {
            entries[index].text = text
        } else {
            entries.append(Entry(
                id: UUID().uuidString,
                kind: .assistant,
                text: text,
                imagePaths: [],
                timestamp: Date()
            ))
        }
        flushTask?.cancel()
        flushTask = nil
        flush()
    }

    func latestAssistantText() -> String? {
        guard let text = entries.last(where: { $0.kind == .assistant })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    func upsertTool(itemID: String, title: String, detail: String, completed: Bool) {
        if let index = entries.lastIndex(where: { $0.id == itemID && $0.kind == .tool }) {
            entries[index].title = title
            entries[index].text = detail
            if completed { entries[index].detail = detail }
        } else {
            entries.append(Entry(
                id: itemID,
                kind: .tool,
                title: title,
                text: detail,
                detail: completed ? detail : nil,
                imagePaths: [],
                timestamp: Date()
            ))
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            await self?.flushScheduled()
        }
    }

    private func flushScheduled() {
        flushTask = nil
        flush()
    }

    private func flush() {
        var lines: [Data] = []
        for entry in entries.suffix(160) {
            var object: [String: JSONValue] = [
                "type": .string("noturcode_native"),
                "id": .string(entry.id),
                "kind": .string(kindName(entry.kind)),
                "text": .string(entry.text),
                "timestamp": .string(ISO8601DateFormatter().string(from: entry.timestamp)),
                "imagePaths": .array(entry.imagePaths.map(JSONValue.string))
            ]
            if let title = entry.title { object["title"] = .string(title) }
            if let detail = entry.detail { object["detail"] = .string(detail) }
            if let model { object["model"] = .string(model) }
            lines.append(encoded(.object(object)))
        }
        let data = lines.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
        try? SecureLocalStorage.writePrivate(data, to: fileURL)
    }

    private func encoded(_ value: JSONValue) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }

    private func kindName(_ kind: Entry.Kind) -> String {
        switch kind {
        case .system: "system"
        case .user: "user"
        case .assistant: "assistant"
        case .tool: "tool"
        }
    }
}
