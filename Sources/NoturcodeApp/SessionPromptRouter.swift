import NoturcodeCore

actor SessionPromptRouter {
    private let terminalSender: ITermPromptSender
    private let nativeSessions: NativeSessionCoordinator

    init(terminalSender: ITermPromptSender, nativeSessions: NativeSessionCoordinator) {
        self.terminalSender = terminalSender
        self.nativeSessions = nativeSessions
    }

    func send(
        _ prompt: String,
        imagePaths: [String] = [],
        to session: TrackedSession
    ) async -> ITermPromptResult {
        if session.nativeSession != nil {
            return await nativeSessions.send(prompt, imagePaths: imagePaths, to: session)
        }
        guard let terminal = session.terminal else { return .missing }
        return await terminalSender.send(prompt, to: terminal, sourceProcessID: session.sourceProcessID)
    }

    func compact(_ session: TrackedSession) async -> ITermPromptResult {
        if session.nativeSession != nil { return await nativeSessions.compact(session) }
        guard let terminal = session.terminal else { return .missing }
        return await terminalSender.send("/compact", to: terminal, sourceProcessID: session.sourceProcessID)
    }
}
