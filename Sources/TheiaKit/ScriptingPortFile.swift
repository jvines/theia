import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The scripting endpoint advertised to local clients. Two decimal lines keep
/// discovery usable from shell without depending on a JSON parser.
public struct ScriptingPortFile {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func write(port: UInt16, pid: Int32 = getpid()) throws {
        let contents = Data("\(port)\n\(pid)\n".utf8)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".scripting-port-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                      mode_t(0o600))
        guard fd >= 0 else { throw ScriptingPortFileError.posix("open", errno) }
        var fdOpen = true
        do {
            try contents.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = DarwinOrGlibcWrite(fd, base.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ScriptingPortFileError.posix("write", errno) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw ScriptingPortFileError.posix("fsync", errno) }
            let closeResult = close(fd)
            fdOpen = false
            guard closeResult == 0 else { throw ScriptingPortFileError.posix("close", errno) }
            guard rename(temporary.path, url.path) == 0 else {
                throw ScriptingPortFileError.posix("rename", errno)
            }
        } catch {
            if fdOpen { _ = close(fd) }
            _ = unlink(temporary.path)
            throw error
        }
    }

    /// Never remove a newer server's port file if one replaced this process.
    public func removeIfMatching(port: UInt16, pid: Int32 = getpid()) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              contents == "\(port)\n\(pid)\n" else { return }
        _ = unlink(url.path)
    }
}

public enum ScriptingPortFileError: Error {
    case posix(String, Int32)
}

private func DarwinOrGlibcWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, bytes, count)
    #else
    Glibc.write(fd, bytes, count)
    #endif
}
