import Foundation

public struct LineJSONRPCMessage: Codable, Equatable, Sendable {
    public var jsonrpc: String?
    public var id: JSONValue?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: JSONValue?

    public init(
        jsonrpc: String? = "2.0",
        id: JSONValue? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONValue? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

public enum JSONRPCLineEvent: Equatable, Sendable {
    case message(LineJSONRPCMessage)
    case malformed(String)
}

public struct JSONRPCLineDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [JSONRPCLineEvent] {
        buffer.append(data)
        var events: [JSONRPCLineEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty else { continue }
            do {
                events.append(.message(try JSONDecoder().decode(LineJSONRPCMessage.self, from: Data(line))))
            } catch {
                events.append(.malformed(String(decoding: line, as: UTF8.self)))
            }
        }
        return events
    }
}

public enum LineJSONRPCProcessError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case launchFailed(String)
    case writeFailed(String)
    case requestFailed(String)
    case timedOut(String)
    case processExited(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The JSON-RPC process is already running."
        case .notRunning: "The JSON-RPC process is not running."
        case let .launchFailed(message): "The JSON-RPC process could not start: \(message)"
        case let .writeFailed(message): "The JSON-RPC request could not be written: \(message)"
        case let .requestFailed(message): "The JSON-RPC request failed: \(message)"
        case let .timedOut(method): "The JSON-RPC request timed out: \(method)"
        case let .processExited(message): "The JSON-RPC process exited: \(message)"
        }
    }
}

public actor LineJSONRPCProcess {
    public struct Configuration: Equatable, Sendable {
        public var executableURL: URL
        public var arguments: [String]
        public var environment: [String: String]

        public init(executableURL: URL, arguments: [String] = [], environment: [String: String] = [:]) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
        }
    }

    public typealias EventHandler = @Sendable (JSONRPCLineEvent) async -> Void

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let configuration: Configuration
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var decoder = JSONRPCLineDecoder()
    private var pending: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var generation = UUID()
    private var eventHandler: EventHandler?
    private var errorTail = ""

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func start(eventHandler: @escaping EventHandler) throws {
        guard process == nil else { throw LineJSONRPCProcessError.alreadyRunning }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        var environment = ProcessInfo.processInfo.environment
        configuration.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let generation = UUID()
        self.generation = generation
        self.eventHandler = eventHandler
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data, generation: generation) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveError(data, generation: generation) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.processDidExit(status: process.terminationStatus, generation: generation) }
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw LineJSONRPCProcessError.launchFailed(error.localizedDescription)
        }
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
    }

    public func request(
        method: String,
        params: JSONValue = .object([:]),
        timeout: Duration = .seconds(10)
    ) async throws -> JSONValue {
        guard process?.isRunning == true else { throw LineJSONRPCProcessError.notRunning }
        let id = nextRequestID
        nextRequestID &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.timeoutRequest(id)
                }
                pending[id] = PendingRequest(method: method, continuation: continuation, timeoutTask: timeoutTask)
                do {
                    try write(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .number(Double(id)),
                        "method": .string(method),
                        "params": params
                    ]))
                } catch {
                    finishRequest(id, with: .failure(error))
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    public func notify(method: String, params: JSONValue = .object([:])) throws {
        guard process?.isRunning == true else { throw LineJSONRPCProcessError.notRunning }
        try write(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ]))
    }

    public func respond(id: JSONValue, result: JSONValue) throws {
        guard process?.isRunning == true else { throw LineJSONRPCProcessError.notRunning }
        try write(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ]))
    }

    public func stop() {
        generation = UUID()
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        failAll(LineJSONRPCProcessError.processExited("stopped"))
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        eventHandler = nil
        decoder = JSONRPCLineDecoder()
    }

    public var isRunning: Bool { process?.isRunning == true }

    private func write(_ value: JSONValue) throws {
        guard let input else { throw LineJSONRPCProcessError.notRunning }
        do {
            var data = try JSONEncoder().encode(value)
            data.append(0x0A)
            try input.write(contentsOf: data)
        } catch {
            throw LineJSONRPCProcessError.writeFailed(error.localizedDescription)
        }
    }

    private func receive(_ data: Data, generation: UUID) async {
        guard generation == self.generation else { return }
        if data.isEmpty { return }
        for event in decoder.append(data) {
            if case let .message(message) = event,
               message.method == nil,
               let id = message.id?.intValue,
               pending[id] != nil {
                if let error = message.error {
                    finishRequest(id, with: .failure(LineJSONRPCProcessError.requestFailed(Self.errorMessage(error))))
                } else {
                    finishRequest(id, with: .success(message.result ?? .null))
                }
            } else {
                await eventHandler?(event)
            }
        }
    }

    private func receiveError(_ data: Data, generation: UUID) {
        guard generation == self.generation, !data.isEmpty else { return }
        errorTail.append(String(decoding: data, as: UTF8.self))
        if errorTail.count > 4_000 { errorTail = String(errorTail.suffix(4_000)) }
    }

    private func timeoutRequest(_ id: Int) {
        guard let request = pending[id] else { return }
        finishRequest(id, with: .failure(LineJSONRPCProcessError.timedOut(request.method)))
    }

    private func cancelRequest(_ id: Int) {
        finishRequest(id, with: .failure(CancellationError()))
    }

    private func finishRequest(_ id: Int, with result: Result<JSONValue, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func processDidExit(status: Int32, generation: UUID) {
        guard generation == self.generation else { return }
        let message = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
        failAll(LineJSONRPCProcessError.processExited(message.isEmpty ? "status \(status)" : message))
        process = nil
        input = nil
        output = nil
        errorOutput = nil
    }

    private func failAll(_ error: Error) {
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private static func errorMessage(_ value: JSONValue) -> String {
        value.firstString(for: ["message", "error"])
            ?? String(describing: value)
    }
}
