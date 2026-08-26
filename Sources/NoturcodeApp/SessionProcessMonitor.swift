import Darwin
import Foundation
import NoturcodeCore

@MainActor
final class SessionProcessMonitor {
    private var sources: [SessionKey: DispatchSourceProcess] = [:]
    private var pendingWatchTokens: [SessionKey: UUID] = [:]
    private let onExit: @MainActor (SessionKey) -> Void

    init(onExit: @escaping @MainActor (SessionKey) -> Void) {
        self.onExit = onExit
    }

    func watch(key: SessionKey, pid: Int32) {
        unwatch(key: key)
        let token = UUID()
        pendingWatchTokens[key] = token
        Task.detached(priority: .utility) { [weak self] in
            let isValid = pid > 1
                && Self.processIsAlive(pid)
                && Self.processLooksLikeAgent(pid)
            await self?.finishWatch(key: key, pid: pid, token: token, isValid: isValid)
        }
    }

    private func finishWatch(key: SessionKey, pid: Int32, token: UUID, isValid: Bool) {
        guard pendingWatchTokens[key] == token else { return }
        pendingWatchTokens[key] = nil
        guard isValid else {
            onExit(key)
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.sources[key]?.cancel()
            self.sources[key] = nil
            self.onExit(key)
        }
        source.resume()
        sources[key] = source
    }

    func unwatch(key: SessionKey) {
        pendingWatchTokens[key] = nil
        sources[key]?.cancel()
        sources[key] = nil
    }

    func stop() {
        pendingWatchTokens.removeAll()
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
    }

    nonisolated private static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    nonisolated private static func processLooksLikeAgent(_ pid: Int32) -> Bool {
        guard let ancestor = ProcessAncestry.inspect(pid: pid) else { return false }
        return ProcessAncestry.isAgentProcess(ancestor.command)
    }
}
