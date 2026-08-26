import CryptoKit
import Foundation

public struct RemotePairRequest: Codable, Equatable, Sendable {
    public let type: String
    public let code: String
    public let deviceID: String
    public let deviceName: String

    public init(code: String, deviceID: String, deviceName: String) {
        type = "remotePair"
        self.code = code
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

public struct RemotePairResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let token: String?
    public let error: String?

    public init(ok: Bool, token: String? = nil, error: String? = nil) {
        self.ok = ok
        self.token = token
        self.error = error
    }
}

public struct RemoteHookRequest: Codable, Equatable, Sendable {
    public let type: String
    public let token: String
    public let deviceID: String
    public let source: AgentSource
    public let payload: JSONValue
    public let environment: [String: String]
    public let sourceProcessID: Int32?
    public let terminalSessionID: String?

    public init(
        token: String,
        deviceID: String,
        source: AgentSource,
        payload: JSONValue,
        environment: [String: String],
        sourceProcessID: Int32? = nil,
        terminalSessionID: String? = nil
    ) {
        type = "remoteHook"
        self.token = token
        self.deviceID = deviceID
        self.source = source
        self.payload = payload
        self.environment = environment
        self.sourceProcessID = sourceProcessID
        self.terminalSessionID = terminalSessionID
    }
}

public struct RemoteHookResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let hookOutput: JSONValue
    public let error: String?

    public init(ok: Bool, hookOutput: JSONValue = .object([:]), error: String? = nil) {
        self.ok = ok
        self.hookOutput = hookOutput
        self.error = error
    }
}

public struct RemoteImagePollRequest: Codable, Equatable, Sendable {
    public let type: String
    public let token: String
    public let deviceID: String
    public let terminalSessionID: String
    public let attachmentID: String?
    public let offset: Int

    public init(token: String, deviceID: String, terminalSessionID: String,
                attachmentID: String? = nil, offset: Int = 0) {
        type = "remoteImagePoll"
        self.token = token
        self.deviceID = deviceID
        self.terminalSessionID = terminalSessionID
        self.attachmentID = attachmentID
        self.offset = offset
    }
}

public struct RemoteImagePollResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let attachmentID: String?
    public let fileName: String?
    public let totalBytes: Int?
    public let offset: Int?
    public let chunk: Data?
    public let error: String?

    public init(ok: Bool, attachmentID: String? = nil, fileName: String? = nil,
                totalBytes: Int? = nil, offset: Int? = nil, chunk: Data? = nil,
                error: String? = nil) {
        self.ok = ok
        self.attachmentID = attachmentID
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.offset = offset
        self.chunk = chunk
        self.error = error
    }
}

public struct RemoteImageReadyRequest: Codable, Equatable, Sendable {
    public let type: String
    public let token: String
    public let deviceID: String
    public let terminalSessionID: String
    public let attachmentID: String
    public let remotePath: String?
    public let error: String?

    public init(token: String, deviceID: String, terminalSessionID: String,
                attachmentID: String, remotePath: String? = nil, error: String? = nil) {
        type = "remoteImageReady"
        self.token = token
        self.deviceID = deviceID
        self.terminalSessionID = terminalSessionID
        self.attachmentID = attachmentID
        self.remotePath = remotePath
        self.error = error
    }
}

public struct RemotePairingCode: Codable, Equatable, Sendable {
    public let code: String
    public let hostHint: String
    public let expiresAt: Date
}

public final class RemotePairingStore: @unchecked Sendable {
    private struct PendingPair: Codable {
        let hostHint: String
        let expiresAt: Date
    }

    private struct PairedDevice: Codable {
        let id: String
        let name: String
        let tokenHash: String
        let pairedAt: Date
    }

    public let directoryURL: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(directoryURL: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else if let override = ProcessInfo.processInfo.environment["NOTURCODE_PAIRING_PATH"], !override.isEmpty {
            self.directoryURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = support
                .appendingPathComponent("Noturcode", isDirectory: true)
                .appendingPathComponent("remote-pairing", isDirectory: true)
        }
        self.now = now
    }

    public func createCode(hostHint: String, lifetime: TimeInterval = 600) throws -> RemotePairingCode {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0..<20 {
            let code = String(format: "%06d", Int.random(in: 0...999_999))
            guard !FileManager.default.fileExists(atPath: pendingURL(code: code).path) else { continue }
            let expiresAt = now().addingTimeInterval(lifetime)
            let pending = PendingPair(hostHint: hostHint, expiresAt: expiresAt)
            let data = try encoder.encode(pending)
            try SecureLocalStorage.writePrivate(data, to: pendingURL(code: code))
            return RemotePairingCode(code: code, hostHint: hostHint, expiresAt: expiresAt)
        }
        throw RemotePairingError.couldNotCreateCode
    }

    public func pair(code: String, deviceID: String, deviceName: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let validDeviceID = !deviceID.isEmpty
            && deviceID.count <= 80
            && deviceID.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard code.count == 6, code.allSatisfy(\.isNumber), validDeviceID else {
            throw RemotePairingError.invalidCode
        }
        let url = pendingURL(code: code)
        guard let data = try? Data(contentsOf: url),
              let pending = try? decoder.decode(PendingPair.self, from: data) else {
            throw RemotePairingError.invalidCode
        }
        guard pending.expiresAt > now() else {
            try? FileManager.default.removeItem(at: url)
            throw RemotePairingError.expiredCode
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let device = PairedDevice(
            id: deviceID,
            name: String(deviceName.prefix(120)),
            tokenHash: Self.hash(token),
            pairedAt: now()
        )
        try SecureLocalStorage.writePrivate(try encoder.encode(device), to: deviceURL(id: deviceID))
        try FileManager.default.removeItem(at: url)
        return token
    }

    public func validates(token: String, deviceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !token.isEmpty,
              let data = try? Data(contentsOf: deviceURL(id: deviceID)),
              let device = try? decoder.decode(PairedDevice.self, from: data) else {
            return false
        }
        return Self.constantTimeEqual(device.tokenHash, Self.hash(token))
    }

    private var pendingDirectoryURL: URL {
        directoryURL.appendingPathComponent("pending", isDirectory: true)
    }

    private var deviceDirectoryURL: URL {
        directoryURL.appendingPathComponent("devices", isDirectory: true)
    }

    private func pendingURL(code: String) -> URL {
        pendingDirectoryURL.appendingPathComponent(code + ".json")
    }

    private func deviceURL(id: String) -> URL {
        let safeID = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return deviceDirectoryURL.appendingPathComponent((safeID.isEmpty ? "invalid" : safeID) + ".json")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum RemotePairingError: LocalizedError {
    case invalidCode
    case expiredCode
    case couldNotCreateCode

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "The pairing code is invalid or was already used."
        case .expiredCode: "The pairing code expired. Run nc and create a new code."
        case .couldNotCreateCode: "Noturcode could not create a unique pairing code. Try again."
        }
    }
}

public struct RemoteHookProcessingResult: Equatable, Sendable {
    public let events: [BridgeEvent]
    public let response: RemoteHookResponse

    public init(events: [BridgeEvent], response: RemoteHookResponse) {
        self.events = events
        self.response = response
    }
}

public final class RemoteBridgeProcessor: @unchecked Sendable {
    public let pairings: RemotePairingStore

    public init(pairings: RemotePairingStore = RemotePairingStore()) {
        self.pairings = pairings
    }

    public func pair(_ request: RemotePairRequest) -> RemotePairResponse {
        do {
            let token = try pairings.pair(
                code: request.code,
                deviceID: request.deviceID,
                deviceName: request.deviceName
            )
            return RemotePairResponse(ok: true, token: token)
        } catch {
            return RemotePairResponse(ok: false, error: error.localizedDescription)
        }
    }

    public func process(_ request: RemoteHookRequest, now: Date = Date()) -> RemoteHookProcessingResult {
        guard pairings.validates(token: request.token, deviceID: request.deviceID) else {
            return RemoteHookProcessingResult(
                events: [],
                response: RemoteHookResponse(
                    ok: false,
                    error: "This VPS is not paired with Noturcode. Run nc and pair it again."
                )
            )
        }
        var normalized = HookNormalizer.normalize(
            payload: request.payload,
            source: request.source,
            environment: request.environment,
            sourceProcessID: request.sourceProcessID,
            terminalSessionIDOverride: request.terminalSessionID,
            now: now
        )
        return RemoteHookProcessingResult(
            events: normalized.events,
            response: RemoteHookResponse(
                ok: true,
                hookOutput: Self.hookOutput(for: normalized.commandResult)
            )
        )
    }

    private static func hookOutput(for commandResult: HookCommandResult?) -> JSONValue {
        guard let commandResult else { return .object([:]) }
        if commandResult.shouldBlockPrompt {
            return .object([
                "decision": .string("block"),
                "reason": .string(commandResult.message)
            ])
        }
        return .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("UserPromptSubmit"),
                "additionalContext": .string(commandResult.message)
            ])
        ])
    }
}
