import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Private, bounded history of SSH FITS locations shared by the app's windows.
public struct RemoteRecentStore {
    public enum StoreError: Error {
        case invalidLocation
        case unsupportedVersion
    }

    private struct Record: Codable {
        let version: Int
        let locations: [String]
    }

    let fileURL: URL

    public init(paths: AppPaths = AppPaths()) {
        fileURL = paths.sessionsDirectory.deletingLastPathComponent()
            .appendingPathComponent("remote-recents.json")
    }

    public func urls(limit: Int = 10) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: fileURL))
        guard record.version == 1 else { throw StoreError.unsupportedVersion }
        return Array(record.locations.compactMap(URL.init(string:))
            .filter(Self.isValid).prefix(max(0, limit)))
    }

    public func record(_ location: URL) throws {
        guard Self.isValid(location) else { throw StoreError.invalidLocation }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path
        )

        let lockURL = directory.appendingPathComponent("remote-recents.lock")
        let descriptor = lockURL.path.withCString { open($0, O_CREAT | O_RDWR, mode_t(0o600)) }
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Self.posixError() }
        defer { _ = flock(descriptor, LOCK_UN) }

        var recent = try urls()
        recent.removeAll { $0.absoluteString == location.absoluteString }
        recent.insert(location, at: 0)
        let data = try JSONEncoder().encode(Record(
            version: 1, locations: recent.prefix(10).map(\.absoluteString)
        ))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path
        )
    }

    private static func isValid(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return parts.scheme?.lowercased() == "ssh"
            && parts.host?.isEmpty == false
            && parts.password == nil
            && parts.query == nil
            && parts.fragment == nil
            && parts.path.hasPrefix("/")
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
