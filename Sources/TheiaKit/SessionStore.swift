import Foundation
import FITSCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Persists document settings in the per-user state directory. The caller passes
/// the FITS bytes it used to open the document so no second disk read is needed.
public struct SessionStore {
    /// Calculated once from the bytes opened by the document and reused by
    /// autosave without retaining or rereading its image data.
    public struct FileIdentity: Sendable {
        public let dataSize: Int
        public let headerFingerprint: String
    }

    public enum LoadResult {
        case none
        case restored(SessionState)
        /// A current save exists, while an earlier changed-file save remains
        /// available for an explicit restore decision.
        case restoredWithStale(current: SessionState, stale: SessionState)
        /// A saved session for an earlier version of this file. Apply only after
        /// the user explicitly chooses "Restore anyway".
        case stale(SessionState)
    }

    public enum StoreError: Error {
        case cannotResolvePath(URL)
        case invalidFITSHeader
        case recordPathCollision(URL)
    }

    private struct Record: Codable {
        let canonicalPath: String
        let dataSize: Int
        let headerFingerprint: String
        let session: SessionState
    }

    private let sessionsDirectory: URL

    public init(paths: AppPaths = AppPaths()) {
        sessionsDirectory = paths.sessionsDirectory
    }

    public func recordURL(for fitsURL: URL) throws -> URL {
        let path = try canonicalPath(for: fitsURL)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return sessionsDirectory.appendingPathComponent("\(name)-\(Self.fnv1a64Hex(Data(path.utf8))).json")
    }

    public func staleRecordURL(for fitsURL: URL) throws -> URL {
        try recordURL(for: fitsURL).deletingPathExtension().appendingPathExtension("stale.json")
    }

    public func save(_ session: SessionState, for fitsURL: URL, fileData: Data) throws {
        try save(session, for: fitsURL, identity: Self.identity(for: fileData))
    }

    public static func identity(for fileData: Data) throws -> FileIdentity {
        FileIdentity(dataSize: fileData.count, headerFingerprint: try headerFingerprint(fileData))
    }

    public func save(_ session: SessionState, for fitsURL: URL, identity: FileIdentity) throws {
        let path = try canonicalPath(for: fitsURL)
        let url = try recordURL(for: fitsURL)
        if let existing = try readRecord(at: url), existing.canonicalPath != path {
            throw StoreError.recordPathCollision(url)
        }
        let record = Record(canonicalPath: path, dataSize: identity.dataSize,
                            headerFingerprint: identity.headerFingerprint, session: session)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func load(for fitsURL: URL, fileData: Data) throws -> LoadResult {
        try load(for: fitsURL, identity: Self.identity(for: fileData))
    }

    public func load(for fitsURL: URL, identity: FileIdentity) throws -> LoadResult {
        let path = try canonicalPath(for: fitsURL)
        let url = try recordURL(for: fitsURL)
        let staleURL = try staleRecordURL(for: fitsURL)
        if let record = try readRecord(at: url), record.canonicalPath == path {
            if record.dataSize == identity.dataSize && record.headerFingerprint == identity.headerFingerprint {
                if let stale = try readRecord(at: staleURL), stale.canonicalPath == path {
                    return .restoredWithStale(current: record.session, stale: stale.session)
                }
                return .restored(record.session)
            }
            if FileManager.default.fileExists(atPath: staleURL.path) {
                let archivedURL = staleURL.deletingPathExtension()
                    .appendingPathExtension("\(UUID().uuidString).json")
                try FileManager.default.moveItem(at: staleURL, to: archivedURL)
                do {
                    try FileManager.default.moveItem(at: url, to: staleURL)
                } catch {
                    try? FileManager.default.moveItem(at: archivedURL, to: staleURL)
                    throw error
                }
            } else {
                try FileManager.default.moveItem(at: url, to: staleURL)
            }
            return .stale(record.session)
        }
        if let stale = try readRecord(at: staleURL), stale.canonicalPath == path {
            return .stale(stale.session)
        }
        let legacy = SessionState.sidecarURL(for: fitsURL)
        if FileManager.default.fileExists(atPath: legacy.path) {
            return .restored(try SessionState.fromJSON(Data(contentsOf: legacy)))
        }
        return .none
    }

    /// Dismisses the pending stale restore offer without touching a current save.
    public func discardStale(for fitsURL: URL) throws {
        let url = try staleRecordURL(for: fitsURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func readRecord(at url: URL) throws -> Record? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return try decoder.decode(Record.self, from: Data(contentsOf: url))
    }

    private func canonicalPath(for url: URL) throws -> String {
        guard let pointer = realpath(url.path, nil) else { throw StoreError.cannotResolvePath(url) }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func fnv1a64Hex(_ bytes: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// Hashes complete 2880-byte header blocks, including the block with END,
    /// then skips each HDU's padded data records to reach the next header.
    private static func headerFingerprint(_ data: Data) throws -> String {
        let blockSize = 2880
        let cardSize = 80
        var offset = 0
        var hash: UInt64 = 0xcbf29ce484222325
        var headerCount = 0
        while offset + blockSize <= data.count {
            var values: [String: Int] = [:]
            var foundEnd = false
            repeat {
                guard offset + blockSize <= data.count else { throw StoreError.invalidFITSHeader }
                let block = data.subdata(in: offset..<(offset + blockSize))
                for byte in block { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
                offset += blockSize
                for cardOffset in stride(from: 0, to: blockSize, by: cardSize) {
                    let card = block.subdata(in: cardOffset..<(cardOffset + cardSize))
                    guard let line = String(data: card, encoding: .ascii) else {
                        throw StoreError.invalidFITSHeader
                    }
                    let keyword = String(line.prefix(8)).trimmingCharacters(in: .whitespaces)
                    if keyword == "END" { foundEnd = true; break }
                    guard line.dropFirst(8).first == "=" else { continue }
                    let token = line.dropFirst(10).prefix(20).split(separator: "/", maxSplits: 1)
                        .first?.trimmingCharacters(in: .whitespaces) ?? ""
                    if let value = Int(token) { values[keyword] = value }
                    if keyword == "GROUPS", token == "T" { values[keyword] = 1 }
                }
            } while !foundEnd
            headerCount += 1
            let length = try dataLength(values)
            let (rounded, overflow) = length.addingReportingOverflow(blockSize - 1)
            guard !overflow else { throw StoreError.invalidFITSHeader }
            let padded = (rounded / blockSize) * blockSize
            let (next, nextOverflow) = offset.addingReportingOverflow(padded)
            guard !nextOverflow, next <= data.count else { throw StoreError.invalidFITSHeader }
            offset = next
        }
        guard headerCount > 0 else { throw StoreError.invalidFITSHeader }
        return String(format: "%016llx", hash)
    }

    private static func dataLength(_ values: [String: Int]) throws -> Int {
        guard let bitpix = values["BITPIX"], bitpix != Int.min,
              let naxis = values["NAXIS"], (0...16).contains(naxis) else {
            throw StoreError.invalidFITSHeader
        }
        if naxis == 0 { return 0 }
        let pcount = values["PCOUNT"] ?? 0
        let gcount = values["GCOUNT"] ?? 1
        guard pcount >= 0, gcount >= 0, abs(bitpix) % 8 == 0, abs(bitpix) > 0 else {
            throw StoreError.invalidFITSHeader
        }
        var pixels = 1
        let firstAxis = values["NAXIS1"] == 0 && values["GROUPS"] == 1 ? 2 : 1
        if firstAxis <= naxis {
            for axis in firstAxis...naxis {
                guard let dimension = values["NAXIS\(axis)"], dimension >= 0 else {
                    throw StoreError.invalidFITSHeader
                }
                let (product, overflow) = pixels.multipliedReportingOverflow(by: dimension)
                guard !overflow else { throw StoreError.invalidFITSHeader }
                pixels = product
            }
        }
        let (elements, a) = pcount.addingReportingOverflow(pixels)
        let (groups, b) = elements.multipliedReportingOverflow(by: gcount)
        let (bytes, c) = groups.multipliedReportingOverflow(by: abs(bitpix) / 8)
        guard !a, !b, !c else { throw StoreError.invalidFITSHeader }
        return bytes
    }
}
