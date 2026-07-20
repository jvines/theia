import SwiftUI
import UniformTypeIdentifiers
import FITSCore

/// Minimal `FileDocument` that ferries a `[Region]` through SwiftUI's `.fileExporter`.
/// Serializes via `RegionFile.format`; uses plain-text content type so any editor opens it.
struct RegionDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .data] }
    static var writableContentTypes: [UTType] { [.plainText] }

    var regions: [Region]

    init(regions: [Region]) { self.regions = regions }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Propagate a parse failure instead of defaulting to an empty set — a
        // malformed .reg must surface as a read error, never silently wipe.
        regions = try RegionFile.parse(text)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let text = RegionFile.format(regions)
        return FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
