import Darwin
import Foundation

public enum BoundedProcessRunnerError: Error, Equatable {
    case timedOut
}

public struct BoundedProcessResult: Equatable, Sendable {
    public let status: Int32
    public let output: Data
    public let error: Data

    public init(status: Int32, output: Data, error: Data) {
        self.status = status
        self.output = output
        self.error = error
    }
}

public enum BoundedProcessRunner {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func store(_ data: Data) {
            lock.lock()
            value = data
            lock.unlock()
        }

        func load() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public static func run(
        executable: String,
        arguments: [String],
        standardInputURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let inputHandle = try standardInputURL.map { try FileHandle(forReadingFrom: $0) }
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        defer { try? inputHandle?.close() }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let output = DataBox()
        let error = DataBox()
        let readers = DispatchGroup()
        let readerQueue = DispatchQueue(
            label: "ro.noturcode.process-output",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        readers.enter()
        readerQueue.async {
            output.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        readerQueue.async {
            error.store(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                if finished.wait(timeout: .now() + 0.5) == .timedOut {
                    try? outputPipe.fileHandleForReading.close()
                    try? errorPipe.fileHandleForReading.close()
                }
            }
            readers.wait()
            throw BoundedProcessRunnerError.timedOut
        }
        readers.wait()
        return BoundedProcessResult(
            status: process.terminationStatus,
            output: output.load(),
            error: error.load()
        )
    }
}
