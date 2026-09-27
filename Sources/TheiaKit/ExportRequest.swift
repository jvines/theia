import Foundation
import FITSCore
import FITSRaster

/// Immutable pixels and display parameters captured when a save panel opens.
/// The image remains valid if playback, blink, or another command changes the view.
public struct RenderSnapshot: Sendable, Equatable {
    public let id: UUID
    public let documentID: UUID
    public let imageRevision: Int
    public let hdu: Int
    public let plane: Int
    public let image: FITSImage
    public let stretch: ImageStretch
    public let colorMap: ColorMap
    public let vmin: Float
    public let vmax: Float
    public let stretchParameter: Float

    @MainActor init(session: DocumentSession, image: FITSImage) {
        id = UUID()
        documentID = session.id
        imageRevision = session.imageRevision
        hdu = session.hdu
        plane = session.plane
        self.image = image
        stretch = session.view.stretch
        colorMap = session.view.colorMap
        vmin = session.view.vmin
        vmax = session.view.vmax
        stretchParameter = session.view.stretchParameter
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// Render and encode off the UI thread. PNG is the default save format.
    public func writeImage(to url: URL) throws {
        let display = DisplayImage(image: image, revision: imageRevision)
        let raster = ViewportRasterizer.renderNative(
            display, stretch: stretch, levels: RasterLevels(vmin: vmin, vmax: vmax),
            colorMap: colorMap, parameter: stretchParameter
        )
        let suffix = url.pathExtension.lowercased()
        let data = try suffix == "tiff" || suffix == "tif"
            ? RasterEncoder.tiff(raster) : RasterEncoder.png(raster)
        try data.write(to: url, options: .atomic)
    }
}

public enum Question: Sendable, Equatable {
    case savePath(suggestedName: String, types: [String])
    case openPath(types: [String], multiple: Bool)
    case numbers(prompt: String, fields: [String])
}

public enum PendingRequest: Sendable, Equatable {
    case exportImage(RenderSnapshot)

    public var documentID: UUID {
        switch self {
        case .exportImage(let snapshot): snapshot.documentID
        }
    }
}

public enum Answer: Sendable, Equatable {
    case path(URL)
    case paths([URL])
    case numbers([Double])
    case cancelled
}

extension DocumentSession {
    private func rejectedAnswer(_ failure: CommandFailure) -> CommandOutcome {
        CommandOutcome(effects: [
            .alert(title: "Export not saved", message: failure.message, style: .warning)
        ], failure: failure)
    }

    func requestImageExport() -> CommandOutcome {
        guard !isClosed else { return CommandOutcome(failure: .documentClosed) }
        guard let image = displayed else { return CommandOutcome(failure: .noDisplayedImage) }
        let snapshot = RenderSnapshot(session: self, image: image)
        pendingExportRequests[snapshot.id] = snapshot
        return CommandOutcome(effects: [
            .ask(.savePath(suggestedName: "image.png", types: ["png", "tiff"]),
                 .exportImage(snapshot))
        ])
    }

    func answer(_ request: PendingRequest, with answer: Answer) -> CommandOutcome {
        guard !isClosed else { return rejectedAnswer(.documentClosed) }
        switch request {
        case .exportImage(let supplied):
            guard let snapshot = pendingExportRequests[supplied.id],
                  snapshot.documentID == id else {
                return rejectedAnswer(.invalidPendingRequest)
            }
            switch answer {
            case .cancelled:
                pendingExportRequests[supplied.id] = nil
                return CommandOutcome()
            case .path(let url):
                guard url.isFileURL else { return rejectedAnswer(.invalidAnswer) }
                pendingExportRequests[supplied.id] = nil
                return CommandOutcome(effects: [.exportImage(snapshot, url)])
            case .paths, .numbers:
                return rejectedAnswer(.invalidAnswer)
            }
        }
    }

    public func close() {
        isClosed = true
        pendingExportRequests.removeAll()
    }
}
