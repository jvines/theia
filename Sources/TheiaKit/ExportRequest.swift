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

/// A cube and render settings captured before the Mac asks for an MP4 path.
/// AVFoundation encoding remains a Mac shell operation.
public struct CubeRenderSnapshot: Sendable, Equatable {
    public let id: UUID
    public let documentID: UUID
    public let imageRevision: Int
    public let hduIndex: Int
    public let hdu: FITSHDU
    public let stretch: ImageStretch
    public let colorMap: ColorMap
    public let vmin: Float
    public let vmax: Float
    public let stretchParameter: Float
    public let fps: Int

    @MainActor init(session: DocumentSession, hdu: FITSHDU) {
        id = UUID()
        documentID = session.id
        imageRevision = session.imageRevision
        hduIndex = session.hdu
        self.hdu = hdu
        stretch = session.view.stretch
        colorMap = session.view.colorMap
        vmin = session.view.vmin
        vmax = session.view.vmax
        stretchParameter = session.view.stretchParameter
        fps = 8
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

public enum Question: Sendable, Equatable {
    case savePath(suggestedName: String, types: [String])
    case openPath(types: [String], multiple: Bool)
    case numbers(prompt: String, fields: [String])
}

public enum PendingRequest: Sendable, Equatable {
    case exportImage(RenderSnapshot)
    case exportCube(CubeRenderSnapshot)

    public var id: UUID {
        switch self {
        case .exportImage(let snapshot): snapshot.id
        case .exportCube(let snapshot): snapshot.id
        }
    }

    public var documentID: UUID {
        switch self {
        case .exportImage(let snapshot): snapshot.documentID
        case .exportCube(let snapshot): snapshot.documentID
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
        let request = PendingRequest.exportImage(snapshot)
        pendingRequests[snapshot.id] = request
        return CommandOutcome(effects: [
            .ask(.savePath(suggestedName: "image.png", types: ["png", "tiff"]),
                 request)
        ])
    }

    func requestCubeExport() -> CommandOutcome {
        guard !isClosed else { return CommandOutcome(failure: .documentClosed) }
        let hdu = file.hdus[self.hdu]
        guard hdu.naxis == 3 else { return CommandOutcome(failure: .unavailableCube) }
        let snapshot = CubeRenderSnapshot(session: self, hdu: hdu)
        let request = PendingRequest.exportCube(snapshot)
        pendingRequests[snapshot.id] = request
        let name = url.deletingPathExtension().lastPathComponent + ".mp4"
        return CommandOutcome(effects: [
            .ask(.savePath(suggestedName: name, types: ["mp4"]), request)
        ])
    }

    func answer(_ request: PendingRequest, with answer: Answer) -> CommandOutcome {
        guard !isClosed else { return rejectedAnswer(.documentClosed) }
        guard let stored = pendingRequests[request.id], stored.documentID == id else {
            return rejectedAnswer(.invalidPendingRequest)
        }
        switch answer {
        case .cancelled:
            pendingRequests[request.id] = nil
            return CommandOutcome()
        case .path(let url):
            guard url.isFileURL else { return rejectedAnswer(.invalidAnswer) }
            pendingRequests[request.id] = nil
            switch stored {
            case .exportImage(let snapshot):
                return CommandOutcome(effects: [.exportImage(snapshot, url)])
            case .exportCube(let snapshot):
                return CommandOutcome(effects: [.exportCube(snapshot, url)])
            }
        case .paths, .numbers:
            return rejectedAnswer(.invalidAnswer)
        }
    }

    public func close() {
        isClosed = true
        pendingRequests.removeAll()
    }
}
