import Foundation
import Observation
import FITSCore
import FITSRaster

/// An image operation's result, kept separate from the source HDU and its cube.
public struct DerivedImage: Equatable {
    public let id: UUID
    public let image: FITSImage
    public let wcs: WCS?
    public let label: String

    public init(image: FITSImage, wcs: WCS?, label: String, id: UUID = UUID()) {
        self.id = id
        self.image = image
        self.wcs = wcs
        self.label = label
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Facts that are stable for the lifetime of an open FITS file. Parsing WCS
/// variants here keeps menu enablement and ordinary view updates cheap.
public struct HDUFacts {
    public let isDisplayableImage: Bool
    public let shape: SIMD2<Int>?
    public let planeCount: Int
    public let wcsVariants: [String]
    public let wcsVariantLabels: [String: String]
    private let wcsByVariant: [String: WCS]

    init(hdu: FITSHDU) {
        let axes = hdu.axes
        isDisplayableImage = hdu.isImage && axes.count >= 2 && axes.allSatisfy { $0 > 0 }
        shape = isDisplayableImage ? SIMD2(axes[0], axes[1]) : nil
        planeCount = axes.dropFirst(2).reduce(1) { count, axis in
            let result = count.multipliedReportingOverflow(by: axis)
            return result.overflow ? 0 : result.partialValue
        }
        wcsVariants = WCS.availableVariants(in: hdu.header)
        wcsVariantLabels = Dictionary(uniqueKeysWithValues: wcsVariants.compactMap { variant in
            hdu.header["WCSNAME\(variant)"]?.stringValue.map { (variant, $0) }
        })
        wcsByVariant = Dictionary(uniqueKeysWithValues: wcsVariants.compactMap { variant in
            WCS(header: hdu.header, variant: variant).map { (variant, $0) }
        })
    }

    public func wcs(variant: String) -> WCS? { wcsByVariant[variant] }
}

/// Source, selection, and displayed-image identity for one open document.
/// Expensive decoded planes are cached by source HDU and plane. A derived image
/// has precedence over that source until an HDU or plane is selected.
@MainActor @Observable public final class DocumentSession {
    public let id = UUID()
    public let url: URL
    public let file: FITSFile
    public let facts: [HDUFacts]
    public let view: ImageViewState
    public let headerEditor = HeaderEditor()
    public let photometry = PhotometryTable()
    public private(set) var hdu: Int
    public private(set) var plane: Int = 0
    public private(set) var sourceWCSVariant: String = ""
    public private(set) var derived: DerivedImage?
    public internal(set) var regionList = RegionList() {
        didSet {
            if regions.isEmpty { previewRegion = nil }
            if regions != oldValue.regions {
                regionRevision &+= 1
                emit(.regionsChanged)
                emit(.persistedFieldChanged)
            }
            if selectedRegionIndex != oldValue.selectedIndex { emit(.selectionChanged) }
        }
    }
    public var regions: [Region] {
        get { regionList.regions }
        set { regionList.replace(newValue, selection: selectedRegionIndex) }
    }
    public internal(set) var regionReplacementRevision = 0
    @ObservationIgnored var regionRevision = 0
    @ObservationIgnored var acceptedRegionLoad: (requestID: UUID, regionRevision: Int, replacementRevision: Int)?
    public var selectedRegionIndex: Int? {
        get { regionList.selectedIndex }
        set { regionList.select(newValue) }
    }
    public var previewRegion: Region? {
        didSet { if previewRegion != oldValue { emit(.overlaysChanged) } }
    }
    public var remoteCrosshair: SIMD2<Double>? {
        didSet { if remoteCrosshair != oldValue { emit(.cursorMoved) } }
    }
    public var mode: DrawMode = .pan {
        didSet {
            if mode != oldValue {
                emit(.selectionChanged)
                emit(.persistedFieldChanged)
            }
        }
    }
    public var profileMarker: ProfileGeometry? {
        didSet { if profileMarker != oldValue { emit(.overlaysChanged) } }
    }
    public var cursor: CursorInfo? {
        didSet { if cursor != oldValue { emit(.cursorMoved) } }
    }
    public var inspectorVisible = true {
        didSet { if inspectorVisible != oldValue { emit(.panelStateChanged) } }
    }
    public var inspectorTab: InspectorTab = .header {
        didSet { if inspectorTab != oldValue { emit(.panelStateChanged) } }
    }
    public var catalogFetchInProgress = false {
        didSet { if catalogFetchInProgress != oldValue { emit(.jobStatusChanged) } }
    }
    public private(set) var playing = false
    public private(set) var fps: Double = 5
    public private(set) var blink: BlinkState?
    public var showGrid = false {
        didSet { if showGrid != oldValue { emitOverlaySettingChange() } }
    }
    public var showCompass = false {
        didSet { if showCompass != oldValue { emitOverlaySettingChange() } }
    }
    public var showColorBar = false {
        didSet { if showColorBar != oldValue { emitOverlaySettingChange() } }
    }
    public private(set) var contourSpec = ContourSpec()
    public private(set) var contourSegments: [Contours.LeveledSegments] = []
    public var imageRevision: Int { view.imageRevision }

    private struct ImageKey: Hashable {
        let hdu: Int
        let plane: Int
    }
    @ObservationIgnored private var imageCache: [ImageKey: FITSImage] = [:]
    @ObservationIgnored internal private(set) var decodedImageCount = 0
    @ObservationIgnored private var lastPlaneAdvance: Date = .now
    @ObservationIgnored private let jobs = SessionJobQueue()
    @ObservationIgnored private var eventObservers: [UUID: @MainActor (SessionEvent) -> Void] = [:]
    @ObservationIgnored private var eventOrigin: CommandOrigin = .user
    @ObservationIgnored private var eventEchoTag: UUID?
    @ObservationIgnored private var persistSelection = true
    @ObservationIgnored var pendingRequests: [UUID: PendingRequest] = [:]
    @ObservationIgnored var isClosed = false

    public init(url: URL, file: FITSFile, stretch: ImageStretch = .linear, colorMap: ColorMap = .gray) {
        let fileFacts = file.hdus.map(HDUFacts.init)
        let initialHDU = file.firstImageHDUIndex ?? 0
        self.url = url
        self.file = file
        self.facts = fileFacts
        self.hdu = initialHDU
        self.sourceWCSVariant = fileFacts[initialHDU].wcsVariants.first ?? ""
        self.view = ImageViewState(stretch: stretch, colorMap: colorMap)
        view.display(sourceImage(), revision: 0)
        view.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .displayParameters:
                self.emit(.displayParametersChanged)
                if self.persistSelection { self.emit(.persistedFieldChanged) }
            case .transform: self.emit(.transformChanged)
            case .imageRevision: self.emit(.imageRevisionChanged)
            }
        }
    }

    /// Register a synchronous observer. Remove it when its consumer closes.
    @discardableResult public func addEventObserver(
        _ observer: @escaping @MainActor (SessionEvent) -> Void
    ) -> UUID {
        let id = UUID()
        eventObservers[id] = observer
        return id
    }

    public func removeEventObserver(_ id: UUID) { eventObservers[id] = nil }

    /// Tag mutations from a command or sync propagation, including nested calls.
    public func withEventContext<T>(
        origin: CommandOrigin, echoTag: UUID? = nil, _ body: () throws -> T
    ) rethrows -> T {
        let previousOrigin = eventOrigin
        let previousTag = eventEchoTag
        eventOrigin = origin
        eventEchoTag = echoTag ?? previousTag
        defer {
            eventOrigin = previousOrigin
            eventEchoTag = previousTag
        }
        return try body()
    }

    private func emit(_ kind: SessionEvent.Kind) {
        let event = SessionEvent(kind: kind, origin: eventOrigin,
                                 echoTag: eventEchoTag, imageRevision: imageRevision)
        for observer in Array(eventObservers.values) { observer(event) }
    }

    private func emitOverlaySettingChange() {
        emit(.displayParametersChanged)
        emit(.persistedFieldChanged)
    }

    public var wcsVariant: String { derived?.wcs?.variant ?? sourceWCSVariant }
    public var availableWCSVariants: [String] {
        if let derived { return derived.wcs.map { [$0.variant] } ?? [] }
        return facts[hdu].wcsVariants
    }
    public var wcsVariantLabels: [String: String] {
        if let derived, let wcs = derived.wcs {
            return wcs.name.map { [wcs.variant: $0] } ?? [:]
        }
        return facts[hdu].wcsVariantLabels
    }

    public var displayed: FITSImage? {
        view.image
    }

    private func sourceImage() -> FITSImage? {
        guard facts.indices.contains(hdu), facts[hdu].isDisplayableImage else { return nil }
        let key = ImageKey(hdu: hdu, plane: plane)
        if let cached = imageCache[key] { return cached }
        guard let image = try? FITSImage(hdu: file.hdus[hdu], plane: plane) else { return nil }
        imageCache[key] = image
        decodedImageCount += 1
        return image
    }

    public var displayedWCS: WCS? {
        if let derived { return derived.wcs }
        guard facts.indices.contains(hdu), displayed != nil else { return nil }
        return facts[hdu].wcs(variant: sourceWCSVariant)
    }

    /// The default levels for a newly displayed image. Zscale reads at most 600
    /// source pixels; a full finite scan is only needed if that sample is empty.
    public static func recommendedLevels(for image: FITSImage) -> RasterLevels {
        let range = image.defaultRange().map { ($0.z1, $0.z2) }
            ?? image.physicalMinMax().map { ($0.min, $0.max) }
        guard let range else { return RasterLevels(vmin: 0, vmax: 1) }
        let lo = Float(range.0)
        let hi = Float(range.1)
        guard lo.isFinite, hi.isFinite else { return RasterLevels(vmin: 0, vmax: 1) }
        return RasterLevels(vmin: lo, vmax: hi)
    }

    public func resetLevels() {
        guard let displayed else { return }
        let levels = Self.recommendedLevels(for: displayed)
        view.vmin = levels.vmin
        view.vmax = levels.vmax
    }

    public func setMinMaxLevels() {
        guard let range = displayed?.physicalMinMax() else { return }
        view.vmin = Float(range.min)
        view.vmax = Float(range.max)
    }

    public func setPercentileLevels(lower: Double, upper: Double) {
        guard let displayed,
              let range = PixelStatistics.percentiles(
                displayed.physicalValues(), lower: lower, upper: upper
              ) else { return }
        view.vmin = Float(range.vmin)
        view.vmax = Float(range.vmax)
    }

    public func setContourSpec(_ spec: ContourSpec) {
        guard spec != contourSpec else { return }
        contourSpec = spec
        recomputeContours()
        emit(.displayParametersChanged)
        emit(.persistedFieldChanged)
    }

    private func recomputeContours() {
        let levels = contourSpec.levels()
        guard contourSpec.enabled, let image = displayed,
              !levels.isEmpty else {
            jobs.cancel(kind: .contours)
            if !contourSegments.isEmpty {
                contourSegments = []
                emit(.overlaysChanged)
            }
            return
        }
        let revision = imageRevision
        if !contourSegments.isEmpty {
            contourSegments = []
            emit(.overlaysChanged)
        }
        let origin = eventOrigin
        let echoTag = eventEchoTag
        jobs.enqueue(
            kind: .contours, imageRevision: revision,
            currentRevision: { [weak self] in self?.imageRevision ?? -1 },
            work: {
                guard let values = try? image.physicalValuesCheckingCancellation() else { return nil }
                return try? Contours.segmentsCheckingCancellation(
                    values: values, width: image.width,
                    height: image.height, levels: levels
                )
            },
            apply: { [weak self] (segments: [Contours.LeveledSegments]) in
                self?.withEventContext(origin: origin, echoTag: echoTag) {
                    self?.contourSegments = segments
                    self?.emit(.overlaysChanged)
                }
            }
        )
    }

    public func idle() async { await jobs.idle() }

    /// The next image HDU of the same width and height, wrapping at the end.
    public var blinkPartner: Int? {
        guard facts.indices.contains(hdu), let shape = facts[hdu].shape, facts.count > 1 else { return nil }
        for step in 1..<facts.count {
            let candidate = (hdu + step) % facts.count
            if facts[candidate].shape == shape { return candidate }
        }
        return nil
    }

    public func setPlaying(_ value: Bool, now: Date = .now) {
        guard !value || facts[hdu].planeCount > 1 else { return }
        if value && !playing { lastPlaneAdvance = now }
        guard playing != value else { return }
        playing = value
        emit(.playbackChanged)
    }

    public func setFPS(_ value: Double) {
        let next = value.isFinite ? min(30, max(1, value)) : 5
        guard fps != next else { return }
        fps = next
        emit(.playbackChanged)
    }

    public func toggleBlink(now: Date = .now) {
        if let blink {
            self.blink = nil
            let previousPersistence = persistSelection
            persistSelection = false
            defer { persistSelection = previousPersistence }
            selectHDU(blink.primary)
            emit(.playbackChanged)
        } else if let partner = blinkPartner {
            blink = BlinkState(primary: hdu, partner: partner,
                               intervalSeconds: 1, startedAt: now)
            emit(.playbackChanged)
        }
    }

    public func tick(now: Date) {
        let previousPersistence = persistSelection
        persistSelection = false
        defer { persistSelection = previousPersistence }
        if let blink {
            let target = blink.currentHDU(at: now)
            if hdu != target { selectHDU(target) }
        }
        let planeCount = facts[hdu].planeCount
        guard playing, planeCount > 1 else { return }
        let interval = 1 / fps
        let elapsed = now.timeIntervalSince(lastPlaneAdvance)
        let completedIntervals = Int((elapsed + interval * 1e-6) / interval)
        guard completedIntervals >= 1 else { return }
        selectPlane((plane + 1) % planeCount)
        // Keep the fractional remainder so a display pulse just past the
        // threshold does not lower the average playback rate.
        lastPlaneAdvance = lastPlaneAdvance.addingTimeInterval(Double(completedIntervals) * interval)
    }

    public func selectHDU(_ index: Int) {
        guard facts.indices.contains(index), index != hdu else { return }
        if playing {
            playing = false
            emit(.playbackChanged)
        }
        hdu = index
        plane = 0
        derived = nil
        sourceWCSVariant = facts[index].wcsVariants.first ?? ""
        view.display(sourceImage(), revision: imageRevision &+ 1)
        recomputeContours()
        emit(.selectionChanged)
        if persistSelection { emit(.persistedFieldChanged) }
    }

    public func selectPlane(_ index: Int) {
        guard facts.indices.contains(hdu), facts[hdu].isDisplayableImage,
              index >= 0, index < facts[hdu].planeCount,
              index != plane || derived != nil else { return }
        plane = index
        derived = nil
        view.display(sourceImage(), revision: imageRevision &+ 1)
        recomputeContours()
        emit(.selectionChanged)
        if persistSelection { emit(.persistedFieldChanged) }
    }

    public func selectWCSVariant(_ variant: String) {
        guard derived == nil, facts[hdu].wcsVariants.contains(variant),
              variant != sourceWCSVariant else { return }
        sourceWCSVariant = variant
        emit(.displayParametersChanged)
    }

    public func setDerived(_ image: DerivedImage?) {
        guard derived != image else { return }
        derived = image
        view.display(image?.image ?? sourceImage(), revision: imageRevision &+ 1)
        recomputeContours()
    }

    /// Apply persisted canvas and region state before the document is made
    /// available to scripting or its first renderer is created.
    public func restoreInitialState(_ saved: SessionState) {
        if facts.indices.contains(saved.selectedHDU) { selectHDU(saved.selectedHDU) }
        selectPlane(saved.selectedPlane)
        view.stretch = saved.stretch
        view.colorMap = saved.colorMap
        view.vmin = Float(saved.vmin)
        view.vmax = Float(saved.vmax)
        view.stretchParameter = Float(saved.stretchParameter)
        regionList.restore(saved.regions)
        if let savedMode = DrawMode(rawValue: saved.drawMode) { mode = savedMode }
        showGrid = saved.showWCSGrid
        showCompass = saved.showCompass
        showColorBar = saved.showColorBar
        if let contour = saved.contour {
            setContourSpec(ContourSpec(
                enabled: contour.enabled, count: contour.count,
                minValue: contour.minValue, maxValue: contour.maxValue,
                spacing: ContourSpec.Spacing(rawValue: contour.spacing) ?? .linear
            ))
        }
    }
}
