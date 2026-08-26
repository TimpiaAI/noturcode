import Foundation
import NoturcodeCore

final class RemoteImageRelayStore: @unchecked Sendable {
    private struct Pending {
        let terminalSessionID: String
        let fileName: String
        let data: Data
        var leased: Bool
        var remotePath: String?
        var error: String?
    }

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private let chunkBytes = 384 * 1_024

    func enqueue(terminalSessionID: String, fileName: String, data: Data) -> String {
        let identifier = UUID().uuidString
        lock.withLock {
            pending[identifier] = Pending(
                terminalSessionID: terminalSessionID,
                fileName: fileName,
                data: data,
                leased: false
            )
        }
        return identifier
    }

    func poll(_ request: RemoteImagePollRequest) -> RemoteImagePollResponse {
        lock.withLock {
            let identifier: String
            if let requested = request.attachmentID {
                identifier = requested
            } else if let available = pending.first(where: {
                $0.value.terminalSessionID == request.terminalSessionID && !$0.value.leased
            })?.key {
                identifier = available
                pending[identifier]?.leased = true
            } else {
                return RemoteImagePollResponse(ok: true)
            }
            guard let item = pending[identifier],
                  item.terminalSessionID == request.terminalSessionID,
                  request.offset >= 0,
                  request.offset <= item.data.count else {
                return RemoteImagePollResponse(ok: false, error: "The image relay request is invalid.")
            }
            let end = min(item.data.count, request.offset + chunkBytes)
            return RemoteImagePollResponse(
                ok: true,
                attachmentID: identifier,
                fileName: item.fileName,
                totalBytes: item.data.count,
                offset: request.offset,
                chunk: item.data.subdata(in: request.offset..<end)
            )
        }
    }

    func complete(_ request: RemoteImageReadyRequest) -> Bool {
        lock.withLock {
            guard var item = pending[request.attachmentID],
                  item.terminalSessionID == request.terminalSessionID else { return false }
            item.remotePath = request.remotePath
            item.error = request.error
            pending[request.attachmentID] = item
            return true
        }
    }

    func result(for identifier: String) -> Result<String, Error>? {
        lock.withLock {
            guard let item = pending[identifier] else { return nil }
            if let path = item.remotePath { return .success(path) }
            if let message = item.error {
                return .failure(NSError(domain: "Noturcode.RemoteImageRelay", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: message]))
            }
            return nil
        }
    }

    func remove(_ identifier: String) {
        _ = lock.withLock { pending.removeValue(forKey: identifier) }
    }
}
