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

    /// Preserve the request-time source pixels when the save sheet stays open.
    public func writeFITS(to url: URL) throws {
        try FITSWriter.write(image, to: url)
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
    case saveImage(RenderSnapshot)
    case slab(SlabRequest)
    case saveRegions(RegionSaveSnapshot)
    case loadRegions(RegionLoadRequest)

    public var id: UUID {
        switch self {
        case .exportImage(let snapshot): snapshot.id
        case .exportCube(let snapshot): snapshot.id
        case .saveImage(let snapshot): snapshot.id
        case .slab(let request): request.id
        case .saveRegions(let snapshot): snapshot.id
        case .loadRegions(let request): request.id
        }
    }

    public var documentID: UUID {
        switch self {
        case .exportImage(let snapshot): snapshot.documentID
        case .exportCube(let snapshot): snapshot.documentID
        case .saveImage(let snapshot): snapshot.documentID
        case .slab(let request): request.documentID
        case .saveRegions(let snapshot): snapshot.documentID
        case .loadRegions(let request): request.documentID
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
    private func rejectedAnswer(_ failure: CommandFailure, for request: PendingRequest) -> CommandOutcome {
        let title: String
        switch request {
        case .exportImage, .exportCube: title = "Export not saved"
        case .saveImage: title = "FITS image not saved"
        case .slab: title = "Slab not extracted"
        case .saveRegions: title = "Regions not saved"
        case .loadRegions: title = "Regions not loaded"
        }
        return CommandOutcome(effects: [
            .alert(title: title, message: failure.message, style: .warning)
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

    func requestImageSave() -> CommandOutcome {
        guard !isClosed else { return CommandOutcome(failure: .documentClosed) }
        guard let image = displayed else { return CommandOutcome(failure: .noDisplayedImage) }
        let snapshot = RenderSnapshot(session: self, image: image)
        let request = PendingRequest.saveImage(snapshot)
        pendingRequests[snapshot.id] = request
        let name = url.deletingPathExtension().lastPathComponent + "-modified.fits"
        return CommandOutcome(effects: [
            .ask(.savePath(suggestedName: name, types: ["fits"]), request)
        ])
    }

    func requestSlab() -> CommandOutcome {
        guard !isClosed else { return CommandOutcome(failure: .documentClosed) }
        let cube = file.hdus[hdu]
        guard cube.naxis == 3 else { return CommandOutcome(failure: .unavailableCube) }
        let slab = SlabRequest(session: self)
        let request = PendingRequest.slab(slab)
        pendingRequests[slab.id] = request
        let prompt = "Sum planes (inclusive) of a \(slab.planeCount)-plane cube. Enter range:"
        return CommandOutcome(effects: [
            .ask(.numbers(prompt: prompt, fields: ["From", "To"]), request)
        ])
    }

    func requestRegionSave() -> CommandOutcome {
        guard !isClosed else { return CommandOutcome(failure: .documentClosed) }
        guard !regions.isEmpty else { return CommandOutcome(failure: .noRegions) }
        let snapshot = RegionSaveSnapshot(session: self)
        let request = PendingRequest.saveRegions(snapshot)
        pendingRequests[snapshot.id] = request
        return CommandOutcome(effects: [
            .ask(.savePath(suggestedName: "regions.reg", types: ["reg"]), request)
        ])
    }

    func requestRegionLoad() -> CommandOutcome {
        guard !isClosed else { return CommandOutcome(failure: .documentClosed) }
        let load = RegionLoadRequest(session: self)
        let request = PendingRequest.loadRegions(load)
        pendingRequests[load.id] = request
        return CommandOutcome(effects: [
            .ask(.openPath(types: ["public.plain-text", "public.data"], multiple: false), request)
        ])
    }

    func answer(_ request: PendingRequest, with answer: Answer) -> CommandOutcome {
        guard !isClosed else { return rejectedAnswer(.documentClosed, for: request) }
        guard let stored = pendingRequests[request.id], stored.documentID == id else {
            return rejectedAnswer(.invalidPendingRequest, for: request)
        }
        switch answer {
        case .cancelled:
            pendingRequests[request.id] = nil
            return CommandOutcome()
        case .path(let url):
            guard url.isFileURL else { return rejectedAnswer(.invalidAnswer, for: stored) }
            if case .slab = stored { return rejectedAnswer(.invalidAnswer, for: stored) }
            pendingRequests[request.id] = nil
            switch stored {
            case .exportImage(let snapshot):
                return CommandOutcome(effects: [.exportImage(snapshot, url)])
            case .exportCube(let snapshot):
                return CommandOutcome(effects: [.exportCube(snapshot, url)])
            case .saveImage(let snapshot):
                return CommandOutcome(effects: [.saveImage(snapshot, url)])
            case .saveRegions(let snapshot):
                return CommandOutcome(effects: [.saveRegions(snapshot, url)])
            case .loadRegions(let load):
                acceptRegionLoad(load)
                return CommandOutcome(effects: [.loadRegions(load, url)])
            case .slab:
                return rejectedAnswer(.invalidAnswer, for: stored)
            }
        case .paths(let urls):
            guard case .loadRegions(let load) = stored,
                  urls.count == 1, let url = urls.first, url.isFileURL else {
                return rejectedAnswer(.invalidAnswer, for: stored)
            }
            pendingRequests[request.id] = nil
            acceptRegionLoad(load)
            return CommandOutcome(effects: [.loadRegions(load, url)])
        case .numbers(let values):
            guard case .slab(let slab) = stored,
                  values.count == 2, values.allSatisfy(\.isFinite) else {
                return rejectedAnswer(.invalidAnswer, for: stored)
            }
            pendingRequests[request.id] = nil
            guard slab.hduIndex == hdu, slab.imageRevision == imageRevision else {
                return rejectedAnswer(.staleRequest, for: stored)
            }
            let maximum = Double(slab.planeCount - 1)
            let a = Int(min(max(values[0], 0), maximum))
            let b = Int(min(max(values[1], 0), maximum))
            return CommandOutcome(effects: [.extractSlab(slab, from: min(a, b), to: max(a, b))])
        }
    }

    private func acceptRegionLoad(_ request: RegionLoadRequest) {
        acceptedRegionLoad = (request.id, regionRevision, regionReplacementRevision)
    }

    public func close() {
        isClosed = true
        invalidateImageOperations()
        cancelSourceDetection()
        cancelCatalogFetch()
        pendingRequests.removeAll()
        acceptedRegionLoad = nil
    }
}
