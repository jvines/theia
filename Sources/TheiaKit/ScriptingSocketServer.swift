import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ScriptingSocketError: Error {
    case posix(String, Int32)
    case noAvailablePort
}

/// A response and an optional action that runs only after every response byte
/// has been accepted by the socket. A failed or abandoned write skips the action.
public struct ScriptingSocketReply: Sendable {
    public let data: Data
    public let didSend: (@MainActor @Sendable () -> Void)?

    public init(data: Data, didSend: (@MainActor @Sendable () -> Void)? = nil) {
        self.data = data
        self.didSend = didSend
    }
}

/// One-request-per-connection IPv4 loopback transport for the scripting API.
/// Socket state belongs to its private serial queue. The request handler always
/// runs on the main actor, where the Mac and Linux app models are dispatched.
public final class ScriptingSocketServer: @unchecked Sendable {
    public static let maxQueuedResponseBytes = 64 * 1024 * 1024

    private let queue = DispatchQueue(label: "theia.scripting.http.socket")
    private let portFile: ScriptingPortFile
    private let portRange: ClosedRange<UInt16>
    private let requestHandler: @MainActor @Sendable (Data) -> ScriptingSocketReply?
    private var state: SocketState?

    public init(portFileURL: URL, portRange: ClosedRange<UInt16> = 4321...4399,
                requestHandler: @escaping @MainActor @Sendable (Data) -> ScriptingSocketReply?) {
        self.portFile = ScriptingPortFile(url: portFileURL)
        self.portRange = portRange
        self.requestHandler = requestHandler
    }

    @discardableResult
    public func start() throws -> UInt16 {
        try queue.sync {
            if let state { return state.port }
            // Process-wide fallback complements SO_NOSIGPIPE / MSG_NOSIGNAL.
            _ = signal(SIGPIPE, SIG_IGN)
            let (fd, port, address) = try Self.bindLoopback(in: portRange)
            do {
                try portFile.write(port: port)
            } catch {
                _ = close(fd) // No dispatch source owns this descriptor yet.
                throw error
            }
            let active = SocketState(fd: fd, port: port, boundIPv4Address: address,
                                     queue: queue, portFile: portFile,
                                     requestHandler: requestHandler)
            state = active
            active.start()
            return port
        }
    }

    public var port: UInt16 { queue.sync { state?.port ?? 0 } }
    public var boundIPv4Address: String? { queue.sync { state?.boundIPv4Address } }

    public func stop() {
        queue.sync {
            state?.stop()
            state = nil
        }
    }

    private static func bindLoopback(in range: ClosedRange<UInt16>) throws -> (Int32, UInt16, String) {
        for candidate in range {
            #if os(Linux)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            #endif
            guard fd >= 0 else { throw ScriptingSocketError.posix("socket", errno) }
            do {
                try configure(fd)
                var address = sockaddr_in()
                #if canImport(Darwin)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                #endif
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = candidate.bigEndian
                address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bound == 0 else { throw ScriptingSocketError.posix("bind", errno) }
                guard listen(fd, SOMAXCONN) == 0 else {
                    throw ScriptingSocketError.posix("listen", errno)
                }
                var actual = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let named = withUnsafeMutablePointer(to: &actual) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(fd, $0, &length)
                    }
                }
                guard named == 0 else { throw ScriptingSocketError.posix("getsockname", errno) }
                let addressString = String(cString: inet_ntoa(actual.sin_addr))
                return (fd, UInt16(bigEndian: actual.sin_port), addressString)
            } catch {
                _ = close(fd)
                if case ScriptingSocketError.posix(let operation, let code) = error,
                   code == EADDRINUSE, (operation == "bind" || operation == "listen") {
                    continue
                }
                throw error
            }
        }
        throw ScriptingSocketError.noAvailablePort
    }

    private static func configure(_ fd: Int32) throws {
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ScriptingSocketError.posix("SO_REUSEADDR", errno)
        }
        #if canImport(Darwin)
        var noSigpipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ScriptingSocketError.posix("SO_NOSIGPIPE", errno)
        }
        #endif
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ScriptingSocketError.posix("O_NONBLOCK", errno)
        }
    }

    fileprivate static func configureAccepted(_ fd: Int32) throws {
        #if canImport(Darwin)
        var noSigpipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ScriptingSocketError.posix("SO_NOSIGPIPE", errno)
        }
        #endif
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ScriptingSocketError.posix("O_NONBLOCK", errno)
        }
    }
}

private final class SocketState: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    let boundIPv4Address: String
    let queue: DispatchQueue
    let portFile: ScriptingPortFile
    let requestHandler: @MainActor @Sendable (Data) -> ScriptingSocketReply?
    var listener: DispatchSourceRead?
    var clients: [Int32: SocketClient] = [:]

    init(fd: Int32, port: UInt16, boundIPv4Address: String, queue: DispatchQueue,
         portFile: ScriptingPortFile,
         requestHandler: @escaping @MainActor @Sendable (Data) -> ScriptingSocketReply?) {
        self.fd = fd
        self.port = port
        self.boundIPv4Address = boundIPv4Address
        self.queue = queue
        self.portFile = portFile
        self.requestHandler = requestHandler
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener = source
        source.setEventHandler { [weak self] in self?.acceptReady() }
        source.setCancelHandler { [fd] in _ = close(fd) }
        source.resume()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) { client.abort() }
        clients.removeAll()
        portFile.removeIfMatching(port: port)
    }

    private func acceptReady() {
        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return // EAGAIN or a terminal listener error.
            }
            do {
                try ScriptingSocketServer.configureAccepted(clientFD)
            } catch {
                _ = close(clientFD) // No dispatch source owns it yet.
                continue
            }
            let client = SocketClient(fd: clientFD, state: self)
            clients[clientFD] = client
            client.start()
        }
    }
}

private final class SocketDescriptorOwner {
    let fd: Int32
    var hasWriteSource = false
    var closed = false

    init(fd: Int32) { self.fd = fd }

    func closeIfNeeded() {
        guard !closed else { return }
        closed = true
        _ = close(fd)
    }
}

private final class SocketClient: @unchecked Sendable {
    let fd: Int32
    weak var state: SocketState?
    let queue: DispatchQueue
    let owner: SocketDescriptorOwner
    let readSource: DispatchSourceRead
    var writeSource: DispatchSourceWrite?
    var input = Data()
    var output = Data()
    var written = 0
    var didSend: (@MainActor @Sendable () -> Void)?
    var readSuspended = false
    var readCanceled = false
    var finished = false

    init(fd: Int32, state: SocketState) {
        self.fd = fd
        self.state = state
        self.queue = state.queue
        self.owner = SocketDescriptorOwner(fd: fd)
        self.readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: state.queue)
    }

    func start() {
        readSource.setEventHandler { [weak self] in self?.readReady() }
        readSource.setCancelHandler { [owner] in
            if !owner.hasWriteSource { owner.closeIfNeeded() }
        }
        readSource.resume()
    }

    private func readReady() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                input.append(contentsOf: chunk.prefix(count))
                switch ScriptingHTTPRequestParser.parse(input) {
                case .incomplete: continue
                case .request, .failure:
                    readSource.suspend()
                    readSuspended = true
                    let request = input
                    let handler = state?.requestHandler
                    Task { @MainActor [weak self] in
                        let reply = handler?(request)
                        self?.queue.async { [weak self] in self?.beginWrite(reply) }
                    }
                    return
                }
            }
            if count == 0 { abort(); return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            abort()
            return
        }
    }

    private func beginWrite(_ reply: ScriptingSocketReply?) {
        guard !finished else { return }
        guard let reply else { abort(); return }
        if reply.data.count > ScriptingSocketServer.maxQueuedResponseBytes {
            output = Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        } else {
            output = reply.data
            didSend = reply.didSend
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        writeSource = source
        owner.hasWriteSource = true
        source.setEventHandler { [weak self] in self?.writeReady() }
        source.setCancelHandler { [owner] in owner.closeIfNeeded() }
        cancelRead()
        source.resume()
    }

    private func writeReady() {
        while written < output.count {
            let sent = output.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                let count = min(65_536, bytes.count - written)
                #if os(Linux)
                return send(fd, base.advanced(by: written), count, Int32(MSG_NOSIGNAL))
                #else
                return send(fd, base.advanced(by: written), count, 0)
                #endif
            }
            if sent > 0 { written += sent; continue }
            if sent < 0 && errno == EINTR { continue }
            if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            abort()
            return
        }
        let completion = didSend
        abort() // The write source's cancel handler closes the descriptor.
        if let completion { Task { @MainActor in completion() } }
    }

    func abort() {
        guard !finished else { return }
        finished = true
        cancelRead()
        writeSource?.cancel()
        state?.clients.removeValue(forKey: fd)
    }

    private func cancelRead() {
        guard !readCanceled else { return }
        readCanceled = true
        readSource.cancel()
        if readSuspended {
            readSuspended = false
            readSource.resume()
        }
    }
}
