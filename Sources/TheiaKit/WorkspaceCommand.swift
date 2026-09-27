import Foundation
import Observation

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
        let observerID = session.addEventObserver { [weak self, weak session] event in
            guard let self, let session else { return }
            self.propagate(event, from: session)
        }
        let id = nextDocumentID
        nextDocumentID += 1
        documents[session.id] = Registration(session: session, observerID: observerID,
                                             documentID: id)
        documentOrder.append(session.id)
        focusedDocumentID = id
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
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let existing = documents.values.compactMap(\.session).first(where: {
            $0.url.standardizedFileURL == url
        }), let id = id(of: existing) {
            focus(existing)
            return WorkspaceOpenResult(session: existing, documentID: id,
                                       wasAlreadyOpen: true, effects: [.documentOpened(id)])
        }
        let session = try load(url)
        register(session)
        let id = self.id(of: session)!
        return WorkspaceOpenResult(session: session, documentID: id,
                                   wasAlreadyOpen: false,
                                   effects: [.documentOpened(id), .noteRecent(url)])
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
            let sky = point.flatMap { source.displayedWCS?.pixelToSky(imageX: $0.x, imageY: $0.y) }
            for target in targets {
                var localPoint = point
                if let sky, let converted = target.displayedWCS?.skyToPixel(ra: sky.ra, dec: sky.dec) {
                    localPoint = SIMD2(converted.x, converted.y)
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
        case .tileWindows:
            return CommandOutcome(effects: [.tileWindows])
        case .quit:
            return CommandOutcome(effects: [.quit])
        }
    }
}
