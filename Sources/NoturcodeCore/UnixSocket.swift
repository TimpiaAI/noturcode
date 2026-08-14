import Darwin
import Foundation

public enum NoturcodeSocket {
    public static var path: String {
        ProcessInfo.processInfo.environment["NOTURCODE_SOCKET_PATH"]
            ?? "/tmp/ro.noturcode.\(getuid()).sock"
    }
}

public enum UnixSocketError: Error, LocalizedError {
    case create(Int32)
    case bind(Int32)
    case listen(Int32)
    case connect(Int32)
    case write(Int32)
    case permissions(Int32)
    case unsafePath
    case invalidPath
    case responseTimeout

    public var errorDescription: String? {
        switch self {
        case let .create(code): "Could not create local socket (errno \(code))."
        case let .bind(code): "Could not bind local socket (errno \(code))."
        case let .listen(code): "Could not listen on local socket (errno \(code))."
        case let .connect(code): "Noturcode is not listening (errno \(code))."
        case let .write(code): "Could not send event to Noturcode (errno \(code))."
        case let .permissions(code): "Could not secure the local socket (errno \(code))."
        case .unsafePath: "The local socket path is not a socket owned by the current user."
        case .invalidPath: "The local socket path is invalid."
        case .responseTimeout: "Noturcode did not acknowledge the event."
        }
    }
}

private func socketAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw UnixSocketError.invalidPath
    }
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
        for (index, byte) in bytes.enumerated() {
            rawBuffer[index] = UInt8(bitPattern: byte)
        }
    }
    return address
}

private func withSockAddr<R>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func socketPathStatus(_ path: String) throws -> stat? {
    var status = stat()
    if lstat(path, &status) == 0 {
        guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK else {
            throw UnixSocketError.unsafePath
        }
        return status
    }
    guard errno == ENOENT else { throw UnixSocketError.connect(errno) }
    return nil
}

public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) -> Data

    private let path: String
    private let queue: DispatchQueue
    private let handler: Handler
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var ownsSocketPath = false

    public init(path: String = NoturcodeSocket.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
        self.queue = DispatchQueue(label: "ro.noturcode.socket", qos: .userInitiated)
    }

    deinit { stop() }

    public func start() throws {
        guard fileDescriptor == -1 else { return }
        if try socketPathStatus(path) != nil {
            if Self.hasLiveListener(at: path) {
                throw UnixSocketError.bind(EADDRINUSE)
            }
            guard unlink(path) == 0 else { throw UnixSocketError.bind(errno) }
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.create(errno) }
        var address = try socketAddress(path: path)
        let bindResult = withSockAddr(&address) { Darwin.bind(descriptor, $0, $1) }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UnixSocketError.bind(code)
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            unlink(path)
            Darwin.close(descriptor)
            throw UnixSocketError.permissions(code)
        }
        ownsSocketPath = true
        guard Darwin.listen(descriptor, 32) == 0 else {
            let code = errno
            ownsSocketPath = false
            unlink(path)
            Darwin.close(descriptor)
            throw UnixSocketError.listen(code)
        }
        fcntl(descriptor, F_SETFL, O_NONBLOCK)
        fileDescriptor = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
        readSource.setCancelHandler { Darwin.close(descriptor) }
        source = readSource
        readSource.resume()
    }

    private static func hasLiveListener(at path: String) -> Bool {
        (try? UnixSocketClient.send(Data("{}".utf8), path: path)) != nil
    }

    public func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        if ownsSocketPath {
            unlink(path)
            ownsSocketPath = false
        }
    }

    private func acceptAvailableConnections() {
        while fileDescriptor >= 0 {
            let client = Darwin.accept(fileDescriptor, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            queue.async { [handler] in
                var input = Data()
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while input.count < 2_000_000 {
                    let count = Darwin.read(client, &buffer, buffer.count)
                    if count > 0 {
                        input.append(buffer, count: count)
                    } else {
                        break
                    }
                }
                let response = handler(input)
                response.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress, !response.isEmpty {
                        _ = Darwin.write(client, base, response.count)
                    }
                }
                Darwin.shutdown(client, SHUT_RDWR)
                Darwin.close(client)
            }
        }
    }
}

public enum UnixSocketClient {
    @discardableResult
    public static func send(_ data: Data, path: String = NoturcodeSocket.path) throws -> Data {
        guard try socketPathStatus(path) != nil else { throw UnixSocketError.connect(ENOENT) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.create(errno) }
        defer { Darwin.close(descriptor) }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = try socketAddress(path: path)
        let result = withSockAddr(&address) { Darwin.connect(descriptor, $0, $1) }
        guard result == 0 else { throw UnixSocketError.connect(errno) }

        let written: Int = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, base, data.count)
        }
        guard written == data.count else { throw UnixSocketError.write(errno) }
        Darwin.shutdown(descriptor, SHUT_WR)

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count >= 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw UnixSocketError.responseTimeout }
            throw UnixSocketError.connect(errno)
        }
        return Data(buffer.prefix(max(0, count)))
    }
}
