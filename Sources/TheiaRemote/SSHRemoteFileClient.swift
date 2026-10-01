import Dispatch
import Foundation
#if os(Linux)
import Glibc
#endif

private func stop(_ process: Process) {
    guard process.isRunning else { return }
    #if os(Linux)
    // Swift worker threads may block SIGTERM; children inherit that mask.
    // SIGKILL ensures cancellation also stops a child spawned on those threads.
    _ = Glibc.kill(process.processIdentifier, SIGKILL)
    #else
    process.terminate()
    #endif
}

public enum SSHRemoteFileError: Error, LocalizedError {
    case helper(String)
    case transport(String)
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .helper(let message): message
        case .transport(let message): message
        case .fileTooLarge: "The remote file is too large for this process"
        }
    }
}

private final class SSHErrorCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, 65_536 - bytes.count)
        bytes.append(chunk.prefix(remaining))
    }

    var message: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class RemoteTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process { stop(process) }
    }

    fileprivate var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    fileprivate func register(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
    }

    fileprivate func clear(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }
}

/// Reads a remote file through a Theia helper. SSH verifies the host using the
/// user's known_hosts file; the path travels only in the versioned stdin protocol.
public struct SSHRemoteFileClient: Sendable {
    /// Seconds SSH waits for the TCP connection. Without it an unreachable host
    /// holds the transfer for the kernel's SYN retry budget, over two minutes.
    public static let connectTimeoutSeconds = 15

    private let executableURL: URL
    private let environment: [String: String]

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executableURL = executableURL
        self.environment = environment
    }

    public func readAsync(_ location: RemoteFileLocation) async throws -> Data {
        let cancellation = RemoteTransferCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try read(location, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func read(_ location: RemoteFileLocation,
                     cancellation: RemoteTransferCancellation? = nil) throws -> Data {
        let request = RemoteWire.readRequest(path: location.path)
        guard request.count <= RemoteWire.maximumHeaderBytes else {
            throw RemoteWireError.headerTooLarge
        }
        let process = Process()
        process.executableURL = executableURL
        process.environment = environment
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                             "-o", "ConnectTimeout=\(Self.connectTimeoutSeconds)"]
            + (location.port.map { ["-p", String($0)] } ?? [])
            + ["--", location.sshTarget, "~/.local/bin/theia-remote-helper"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try cancellation?.register(process)
        defer { cancellation?.clear(process) }
        try process.run()
        if cancellation?.isCancelled == true {
            stop(process)
            process.waitUntilExit()
            throw CancellationError()
        }

        let captured = SSHErrorCapture()
        let stderrDrained = DispatchGroup()
        stderrDrained.enter()
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 4096),
                  !chunk.isEmpty {
                captured.append(chunk)
            }
            stderrDrained.leave()
        }
        var waited = false
        func finish() {
            if !waited {
                process.waitUntilExit()
                waited = true
            }
            stderrDrained.wait()
        }

        do {
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
            let response = try RemoteWire.readHeader(from: output.fileHandleForReading)
            if let error = response.error { throw SSHRemoteFileError.helper(error) }
            guard let size = response.size, size <= UInt64(Int.max) else {
                throw SSHRemoteFileError.fileTooLarge
            }
            var data = Data()
            var remaining = size
            while remaining > 0 {
                let count = Int(min(remaining, 1_048_576))
                guard let chunk = try output.fileHandleForReading.read(upToCount: count),
                      !chunk.isEmpty else {
                    throw RemoteWireError.unexpectedEOF
                }
                data.append(chunk)
                remaining -= UInt64(chunk.count)
            }
            guard try output.fileHandleForReading.read(upToCount: 1)?.isEmpty != false else {
                throw RemoteWireError.invalidRequest
            }
            finish()
            guard process.terminationStatus == 0 else {
                throw SSHRemoteFileError.transport(captured.message.isEmpty
                    ? "SSH helper exited with status \(process.terminationStatus)"
                    : captured.message)
            }
            return data
        } catch {
            try? input.fileHandleForWriting.close()
            stop(process)
            finish()
            if cancellation?.isCancelled == true { throw CancellationError() }
            if error is SSHRemoteFileError { throw error }
            if !captured.message.isEmpty { throw SSHRemoteFileError.transport(captured.message) }
            throw error
        }
    }
}
