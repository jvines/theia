import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum RemoteWireError: Error, LocalizedError {
    case invalidLocation
    case invalidRequest
    case unsupportedVersion
    case headerTooLarge
    case unexpectedEOF
    case notRegularFile

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: "The SSH location must name an absolute file path and a host"
        case .invalidRequest: "Invalid remote file request"
        case .unsupportedVersion: "Incompatible Theia remote helper protocol"
        case .headerTooLarge: "The remote protocol header is too large"
        case .unexpectedEOF: "The remote file transfer ended early"
        case .notRegularFile: "The remote path is not a regular file"
        }
    }
}

public struct RemoteFileLocation: Sendable, Equatable {
    public let url: URL
    public let sshTarget: String
    public let port: Int?
    public let path: String

    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "ssh",
              let host = parts.host, !host.isEmpty, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              }),
              parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/"), !parts.path.contains("\0"),
              parts.path.utf8.count <= 4096,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw RemoteWireError.invalidLocation
        }
        let path = parts.path
        if let user = parts.user {
            guard !user.isEmpty, !user.contains("@"),
                  user.unicodeScalars.allSatisfy({
                      !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw RemoteWireError.invalidLocation
            }
            sshTarget = "\(user)@\(host)"
        } else {
            sshTarget = host
        }
        self.url = url
        self.port = parts.port
        self.path = path
    }
}

public enum RemoteWire {
    public static let version = 1
    public static let maximumHeaderBytes = 16_384

    private struct Request: Codable {
        let version: Int
        let operation: String
        let path: String
    }

    public struct Header: Codable, Sendable {
        public let version: Int
        public let size: UInt64?
        public let error: String?

        fileprivate init(size: UInt64? = nil, error: String? = nil) {
            version = RemoteWire.version
            self.size = size
            self.error = error
        }
    }

    public static func readRequest(path: String) -> Data {
        let request = Request(version: version, operation: "read", path: path)
        var data = try! JSONEncoder().encode(request)
        data.append(0x0a)
        return data
    }

    public static func readHeader(from input: FileHandle) throws -> Header {
        let header = try JSONDecoder().decode(Header.self, from: readLine(from: input))
        guard header.version == version else { throw RemoteWireError.unsupportedVersion }
        guard (header.size != nil) != (header.error != nil) else {
            throw RemoteWireError.invalidRequest
        }
        return header
    }

    fileprivate static func decodeRequest(from input: FileHandle) throws -> String {
        let request = try JSONDecoder().decode(Request.self, from: readLine(from: input))
        guard request.version == version else { throw RemoteWireError.unsupportedVersion }
        guard request.operation == "read", request.path.hasPrefix("/"),
              !request.path.contains("\0"), request.path.utf8.count <= 4096 else {
            throw RemoteWireError.invalidRequest
        }
        return request.path
    }

    fileprivate static func write(_ header: Header, to output: FileHandle) throws {
        var data = try JSONEncoder().encode(header)
        data.append(0x0a)
        try output.write(contentsOf: data)
    }

    private static func readLine(from input: FileHandle) throws -> Data {
        var data = Data()
        while data.count < maximumHeaderBytes {
            guard let byte = try input.read(upToCount: 1), !byte.isEmpty else {
                throw RemoteWireError.unexpectedEOF
            }
            if byte[0] == 0x0a { return data }
            data.append(byte)
        }
        throw RemoteWireError.headerTooLarge
    }
}

public enum RemoteHelper {
    /// Serves one read request; stdout contains only the versioned header and file bytes.
    @discardableResult public static func serve(input: FileHandle, output: FileHandle) -> Int32 {
        var headerSent = false
        do {
            let path = try RemoteWire.decodeRequest(from: input)
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            var attributes = stat()
            guard fstat(file.fileDescriptor, &attributes) == 0,
                  attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  attributes.st_size >= 0 else {
                throw RemoteWireError.notRegularFile
            }
            var remaining = UInt64(attributes.st_size)
            try RemoteWire.write(.init(size: remaining), to: output)
            headerSent = true
            while remaining > 0 {
                let count = Int(min(remaining, 1_048_576))
                guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else {
                    throw RemoteWireError.unexpectedEOF
                }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
            return 0
        } catch {
            if !headerSent {
                try? RemoteWire.write(.init(error: error.localizedDescription), to: output)
            }
            return 1
        }
    }
}
