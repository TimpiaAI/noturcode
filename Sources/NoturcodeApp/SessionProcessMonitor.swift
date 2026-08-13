import Darwin
import Foundation
import NoturcodeCore

@MainActor
final class SessionProcessMonitor {
    private var sources: [SessionKey: DispatchSourceProcess] = [:]
    private let onExit: @MainActor (SessionKey) -> Void

    init(onExit: @escaping @MainActor (SessionKey) -> Void) {
        self.onExit = onExit
    }

    func watch(key: SessionKey, pid: Int32) {
        unwatch(key: key)
        guard pid > 1, processIsAlive(pid), processLooksLikeAgent(pid) else {
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
        sources[key]?.cancel()
        sources[key] = nil
    }

    func stop() {
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func processLooksLikeAgent(_ pid: Int32) -> Bool {
        guard let ancestor = ProcessAncestry.inspect(pid: pid) else { return false }
        let name = URL(fileURLWithPath: ancestor.command).lastPathComponent.lowercased()
        return name.contains("codex") || name.contains("claude") || name == "node" || name == "bun"
    }
}
