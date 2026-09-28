import Foundation
import Glibc
import TheiaKit

/// Owns the files used by one Theia process on a shared Linux host.
@MainActor final class GTKInstanceRuntime {
    let directory: URL

    init(paths: AppPaths) throws {
        let root = try paths.runtimeDirectory()
        directory = root.appendingPathComponent(
            "instance-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        guard mkdir(directory.path, mode_t(0o700)) == 0 else {
            throw GTKXPARuntime.RuntimeError.unsafePath
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o700) else {
            try? FileManager.default.removeItem(at: directory)
            throw GTKXPARuntime.RuntimeError.unsafePath
        }
    }

    func stop() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Runs xpans within one instance's private directory.
@MainActor final class GTKXPARuntime {
    enum RuntimeError: LocalizedError {
        case unsafePath
        case socketPathTooLong
        case missingNameServer
        case nameServerDidNotStart

        var errorDescription: String? {
            switch self {
            case .unsafePath: "XPA instance directory is not private"
            case .socketPathTooLong: "XPA socket path exceeds the Unix socket limit"
            case .missingNameServer: "Bundled xpans executable is missing"
            case .nameServerDidNotStart: "XPA name server did not create its Unix socket"
            }
        }
    }

    let instanceDirectory: URL
    let nameServerSocket: URL
    private let process: Process
    private var stopped = false

    init(instanceDirectory directory: URL, executableDirectory: URL) throws {
        let socket = directory.appendingPathComponent("xpans_unix")
        guard directory.path.utf8.count + 1 + 48 < 108,
              socket.path.utf8.count < 108 else {
            throw RuntimeError.socketPathTooLong
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw RuntimeError.unsafePath
        }
        let executable = executableDirectory.appendingPathComponent("xpans")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RuntimeError.missingNameServer
        }
        instanceDirectory = directory
        nameServerSocket = socket
        process = Process()
        process.executableURL = executable
        process.arguments = ["-f", socket.path]
        var environment = ProcessInfo.processInfo.environment
        environment["XPA_METHOD"] = "unix"
        environment["XPA_TMPDIR"] = directory.path
        environment["XPA_NSUNIX"] = socket.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            var socketInfo = stat()
            var ready = false
            for _ in 0..<100 {
                if lstat(socket.path, &socketInfo) == 0,
                   socketInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) {
                    ready = true
                    break
                }
                guard process.isRunning else { break }
                usleep(10_000)
            }
            guard ready else {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                throw RuntimeError.nameServerDidNotStart
            }
        } catch {
            throw error
        }
        setenv("XPA_METHOD", "unix", 1)
        setenv("XPA_TMPDIR", directory.path, 1)
        setenv("XPA_NSUNIX", socket.path, 1)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if process.isRunning {
            process.terminate()
            for _ in 0..<100 where process.isRunning { usleep(10_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }
}
