import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ScriptingTokenError: Error {
    case insecureExistingFile
    case invalidExistingToken
    case cannotCreateTemporaryFile(Int32)
    case cannotWrite(Int32)
    case cannotPublish(Int32)
}

/// Persists a 256-bit local scripting token without exposing it in logs.
public struct ScriptingTokenStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func loadOrCreate() throws -> String {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return try readExisting() }
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var random = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: 0...255, using: &random))
        }.joined()
        let temporary = directory.appendingPathComponent(".scripting-token-\(UUID().uuidString)")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw ScriptingTokenError.cannotCreateTemporaryFile(errno) }
        defer {
            _ = close(descriptor)
            _ = temporary.path.withCString { unlink($0) }
        }

        let bytes = Array(token.utf8)
        try bytes.withUnsafeBytes { raw in
            var written = 0
            while written < bytes.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ScriptingTokenError.cannotWrite(errno) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ScriptingTokenError.cannotWrite(errno) }

        let linked = temporary.path.withCString { source in
            url.path.withCString { destination in link(source, destination) }
        }
        if linked == 0 { return token }
        if errno == EEXIST { return try readExisting() }
        throw ScriptingTokenError.cannotPublish(errno)
    }

    private func readExisting() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 == 0,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue,
              owner == Int(getuid()) else {
            throw ScriptingTokenError.insecureExistingFile
        }
        let token = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 64,
              token.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ScriptingTokenError.invalidExistingToken
        }
        return token
    }

    public static func authorise(headerValue: String?, token: String) -> Bool {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespaces),
              raw.lowercased().hasPrefix("bearer ") else { return false }
        let supplied = raw.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        let left = Array(supplied.utf8)
        let right = Array(token.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
