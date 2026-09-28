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
    let staleState: SessionState?
    let sessionStore: SessionStore
    let fileIdentity: SessionStore.FileIdentity?
    let persistenceErrorMessage: String?

    convenience init(url: URL, paths: AppPaths = AppPaths()) throws {
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
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
        try self.init(url: url, data: data, paths: paths)
    }

    init(url: URL, data: Data, paths: AppPaths = AppPaths()) throws {
        self.url = url
        self.sessionStore = SessionStore(paths: paths)
        self.file = try FITSFile(data: data)
        self.session = DocumentSession(
            url: url, file: file,
            stretch: UserPreferences.shared.defaultStretch,
            colorMap: UserPreferences.shared.defaultColorMap,
            zscaleContrast: { UserPreferences.shared.zscaleContrast },
            catalogClient: AppCatalog.client
        )
        var identity: SessionStore.FileIdentity?
        var restored: SessionState?
        var stale: SessionState?
        var persistenceError: String?
        do {
            let currentIdentity = try SessionStore.identity(for: data)
            identity = currentIdentity
            switch try sessionStore.load(for: url, identity: currentIdentity) {
            case .none: break
            case .restored(let state): restored = state
            case .restoredWithStale(let current, let archived):
                restored = current
                stale = archived
            case .stale(let state): stale = state
            }
        } catch {
            persistenceError = error.localizedDescription
        }
        self.fileIdentity = identity
        self.restoredState = restored
        self.staleState = stale
        self.persistenceErrorMessage = persistenceError
        if let restoredState { session.restoreInitialState(restoredState) }
    }
}
