import Foundation
import Observation
import FITSCore

public enum HelpDestination: Sendable, Equatable {
    case documentation
    case source
    case reportIssue

    public var url: URL {
        switch self {
        case .documentation: URL(string: "https://jvines.cl/fitsviewer")!
        case .source: URL(string: "https://github.com/jvines/fitsviewer")!
        case .reportIssue: URL(string: "https://github.com/jvines/fitsviewer/issues/new")!
        }
    }
}

public enum WorkspaceCommand: Sendable {
    case showAppWindow(AppWindowKind)
    case openHelp(HelpDestination)
    case setSyncFlag(SyncFlag, Bool)
    case stack(documentID: Int, mode: StackMode)
    case lightCurve(documentID: Int)
    case tileWindows
    case quit
}

public enum SyncFlag: String, CaseIterable, Hashable, Sendable {
    case zoomPan
    case scale
    case colormap
    case crosshair
}

/// A synchronous open decision; the platform creates or raises its window from
/// the returned effects after the shared session has been registered.
@MainActor public struct WorkspaceOpenResult {
    public let session: DocumentSession
    public let documentID: Int
    public let wasAlreadyOpen: Bool
    public let effects: [Effect]
}

/// App-level commands and shared state for all open documents.
@MainActor @Observable public final class Workspace {
    private var enabledSyncFlags: Set<SyncFlag> = []
    @ObservationIgnored private var documents: [UUID: Registration] = [:]
    @ObservationIgnored private var documentOrder: [UUID] = []
    @ObservationIgnored private var nextDocumentID = 0
    public private(set) var focusedDocumentID: Int?

    private struct Registration {
        weak var session: DocumentSession?
        let observerID: UUID
        let documentID: Int
    }

    public init() {}

    public func syncEnabled(_ flag: SyncFlag) -> Bool {
        enabledSyncFlags.contains(flag)
    }

    public func register(_ session: DocumentSession) {
        if documents[session.id] != nil {
            focus(session)
            return
        }
        let id = nextDocumentID
        nextDocumentID += 1
        documents[session.id] = Registration(session: session, observerID: observe(session),
                                             documentID: id)
        documentOrder.append(session.id)
        focusedDocumentID = id
    }

    private func observe(_ session: DocumentSession) -> UUID {
        session.addEventObserver { [weak self, weak session] event in
            guard let self, let session else { return }
            self.propagate(event, from: session)
        }
    }

    public func unregister(_ session: DocumentSession) {
        guard let registration = documents.removeValue(forKey: session.id) else { return }
        session.removeEventObserver(registration.observerID)
        documentOrder.removeAll { $0 == session.id }
        if focusedDocumentID == registration.documentID {
            focusedDocumentID = documentOrder.last.flatMap { documents[$0]?.documentID }
        }
    }

    public func id(of session: DocumentSession) -> Int? {
        documents[session.id]?.documentID
    }

    public func document(at id: Int) -> DocumentSession? {
        documents.values.first { $0.documentID == id }?.session
    }

    public func focus(_ session: DocumentSession) {
        guard let id = documents[session.id]?.documentID else { return }
        focusedDocumentID = id
    }

    public func open(
        path: String, load: (URL) throws -> DocumentSession
    ) throws -> WorkspaceOpenResult {
        try open(url: URL(fileURLWithPath: path), load: load)
    }

    public func open(
        url: URL, load: (URL) throws -> DocumentSession
    ) throws -> WorkspaceOpenResult {
        let url = url.isFileURL ? url.standardizedFileURL : url
        if let opened = raiseIfOpen(url) { return opened }
        let session = try load(url)
        register(session)
        let id = self.id(of: session)!
        return WorkspaceOpenResult(session: session, documentID: id,
                                   wasAlreadyOpen: false,
                                   effects: [.documentOpened(id), .noteRecent(url)])
    }

    /// Opens `url` in place of `replaced`, as DS9 loads a file into the current
    /// frame: the new document takes the replaced one's id and place, so the
    /// frame number scripts see is unchanged. The platform then swaps the
    /// windows. A file that is already open is raised instead, and `replaced`
    /// is left alone.
    public func open(
        url: URL, replacing replaced: DocumentSession, load: (URL) throws -> DocumentSession
    ) throws -> WorkspaceOpenResult {
        let url = url.isFileURL ? url.standardizedFileURL : url
        if let opened = raiseIfOpen(url) { return opened }
        guard let old = documents[replaced.id] else { return try open(url: url, load: load) }
        let session = try load(url)
        replaced.removeEventObserver(old.observerID)
        documents[replaced.id] = nil
        documents[session.id] = Registration(session: session, observerID: observe(session),
                                             documentID: old.documentID)
        if let index = documentOrder.firstIndex(of: replaced.id) {
            documentOrder[index] = session.id
        } else {
            documentOrder.append(session.id)
        }
        focusedDocumentID = old.documentID
        return WorkspaceOpenResult(session: session, documentID: old.documentID,
                                   wasAlreadyOpen: false,
                                   effects: [.documentOpened(old.documentID)]
                                       + (url.isFileURL ? [.noteRecent(url)] : []))
    }

    private func raiseIfOpen(_ url: URL) -> WorkspaceOpenResult? {
        guard let existing = documents.values.compactMap(\.session).first(where: {
            ($0.url.isFileURL ? $0.url.standardizedFileURL : $0.url) == url
        }), let id = id(of: existing) else { return nil }
        focus(existing)
        return WorkspaceOpenResult(session: existing, documentID: id,
                                   wasAlreadyOpen: true, effects: [.documentOpened(id)])
    }

    private func propagate(_ event: SessionEvent, from source: DocumentSession) {
        guard event.echoTag == nil else { return }
        let targets = documents.values.compactMap(\.session).filter { $0.id != source.id }
        guard !targets.isEmpty else { return }
        let tag = UUID()
        switch event.kind {
        case .transformChanged where syncEnabled(.zoomPan):
            let transform = source.view.transform
            for target in targets where target.view.transform != transform {
                target.withEventContext(origin: event.origin, echoTag: tag) {
                    target.view.transform = transform
                }
            }
        case .displayParametersChanged:
            let scale = syncEnabled(.scale)
            let colormap = syncEnabled(.colormap)
            guard scale || colormap else { return }
            for target in targets {
                target.withEventContext(origin: event.origin, echoTag: tag) {
                    if scale {
                        if target.view.vmin != source.view.vmin { target.view.vmin = source.view.vmin }
                        if target.view.vmax != source.view.vmax { target.view.vmax = source.view.vmax }
                    }
                    if colormap && target.view.colorMap != source.view.colorMap {
                        target.view.colorMap = source.view.colorMap
                    }
                }
            }
        case .cursorMoved where syncEnabled(.crosshair):
            let point = source.cursor.map {
                SIMD2(Double($0.imageX), Double($0.imageY))
            }
            let sourceWCS = source.displayedWCS
            let sky = point.flatMap { sourceWCS?.pixelToSky(imageX: $0.x, imageY: $0.y) }
            for target in targets {
                var localPoint = point
                if let sky, let sourceWCS, let targetWCS = target.displayedWCS {
                    let native = CelestialTransform.convert(
                        lon: sky.ra, lat: sky.dec,
                        from: sourceWCS.nativeFrame, to: targetWCS.nativeFrame
                    )
                    localPoint = targetWCS.skyToPixel(ra: native.lon, dec: native.lat)
                        .map { SIMD2($0.x, $0.y) }
                } else if sourceWCS != nil && target.displayedWCS != nil {
                    localPoint = nil
                }
                if target.remoteCrosshair != localPoint {
                    target.withEventContext(origin: event.origin, echoTag: tag) {
                        target.remoteCrosshair = localPoint
                    }
                }
            }
        default: break
        }
    }

    public func clearCrosshairs(origin: CommandOrigin = .user) {
        let tag = UUID()
        for session in documents.values.compactMap(\.session) where session.remoteCrosshair != nil {
            session.withEventContext(origin: origin, echoTag: tag) {
                session.remoteCrosshair = nil
            }
        }
    }

    @discardableResult public func perform(
        _ command: WorkspaceCommand, origin: CommandOrigin
    ) -> CommandOutcome {
        switch command {
        case .showAppWindow(let window):
            guard origin == .user else {
                return CommandOutcome(failure: .requiresUserInterface)
            }
            return CommandOutcome(effects: [.showAppWindow(window)])
        case .openHelp(let destination):
            guard origin == .user else {
                return CommandOutcome(failure: .requiresUserInterface)
            }
            return CommandOutcome(effects: [.openURL(destination.url)])
        case .setSyncFlag(let flag, let enabled):
            if enabled { enabledSyncFlags.insert(flag) }
            else {
                enabledSyncFlags.remove(flag)
                if flag == .crosshair { clearCrosshairs(origin: origin) }
            }
            return CommandOutcome()
        case .stack(let documentID, let mode):
            guard let reference = document(at: documentID) else {
                return CommandOutcome(failure: .documentClosed)
            }
            let otherImages = documentOrder.compactMap { documents[$0]?.session }
                .filter { $0 !== reference }
                .compactMap(\.displayed)
            return reference.stack(with: otherImages, mode: mode, origin: origin)
        case .lightCurve(let documentID):
            guard let reference = document(at: documentID) else {
                return CommandOutcome(failure: .documentClosed)
            }
            guard let selected = reference.selectedRegionIndex,
                  reference.regions.indices.contains(selected) else {
                return CommandOutcome(failure: .noSelectedRegion)
            }
            guard let referenceWCS = reference.displayedWCS else {
                return CommandOutcome(failure: .noDisplayedWCS)
            }
            let frames = documentOrder.compactMap { documents[$0]?.session }
                .compactMap { session -> LightCurveFrame? in
                    guard session.file.hdus.indices.contains(session.hdu),
                          let image = session.displayed,
                          let wcs = session.displayedWCS else { return nil }
                    return LightCurveFrame(image: image, wcs: wcs,
                                           header: session.file.hdus[session.hdu].header)
                }
            guard let curve = LightCurveBuilder.build(
                region: reference.regions[selected], referenceWCS: referenceWCS,
                frames: frames
            ) else {
                return CommandOutcome(failure: .insufficientLightCurveFrames)
            }
            return CommandOutcome(effects: [.openLightCurve(curve)])
        case .tileWindows:
            return CommandOutcome(effects: [.tileWindows])
        case .quit:
            return CommandOutcome(effects: [.quit])
        }
    }
}
