import Foundation
import FITSCore
import FITSRender
import TheiaKit

/// Replaces `FITSDocument` (the SwiftUI `FileDocument`) for the AppKit-owned
/// window path. The shared session owns the canvas state used by the window.
@MainActor final class DocumentModel {
    let url: URL
    let file: FITSFile
    let session: DocumentSession
    let restoredState: SessionState?

    init(url: URL) throws {
        self.url = url
        // mmap large files (≥ 50 MB) so we don't double the file size in RAM and so
        // page cache absorbs OS-level access patterns. Small files use the regular
        // path — the dispatch_io machinery has overhead that isn't worth it for
        // typical < few MB FITS.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let data: Data
        if size >= 50 * 1024 * 1024 {
            data = try Data(contentsOf: url, options: [.alwaysMapped])
        } else {
            data = try Data(contentsOf: url)
        }
        self.file = try FITSFile(data: data)
        self.session = DocumentSession(
            url: url, file: file,
            stretch: UserPreferences.shared.defaultStretch,
            colorMap: UserPreferences.shared.defaultColorMap
        )
        let savedData = try? Data(contentsOf: SessionState.sidecarURL(for: url))
        self.restoredState = savedData.flatMap { try? SessionState.fromJSON($0) }
        if let restoredState { session.restoreInitialState(restoredState) }
    }
}
