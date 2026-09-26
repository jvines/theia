import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FITSCore
import FITSRender

struct DocumentView: View {
    @ObservedObject var document: DocumentModel
    @ObservedObject var toolbarState: ToolbarState
    let toolbarController: FITSToolbarController

    @State private var selectedHDU: Int
    @State private var selectedPlane: Int = 0
    @State private var planePlaying: Bool = false
    @State private var planeFPS: Double = 5
    @State private var lastPlaneAdvance: Date = .now
    @State private var stretch: ImageStretch = UserPreferences.shared.defaultStretch
    @State private var colorMap: ColorMap = UserPreferences.shared.defaultColorMap
    @State private var showInspector: Bool = true
    @State private var showWCSGrid: Bool = false
    @State private var showCompass: Bool = false
    @State private var showColorBar: Bool = false
    @State private var contourSpec: ContourSpec = ContourSpec()
    @State private var contourSegments: [Contours.LeveledSegments] = []
    @State private var activeWCSVariant: String = ""
    @State private var profileGeometry: ProfileGeometry? = nil
    @State private var drawMode: DrawMode = .pan
    @State private var regions: [Region] = []
    @State private var selectedRegionIndex: Int? = nil
    @State private var previewRegion: Region? = nil
    @State private var resetLevelsTrigger: Int = 0
    @State private var cursor: CursorInfo?
    @State private var isFetchingCatalog: Bool = false
    @State private var blinkState: BlinkState? = nil
    @State private var displayOverride: DisplayOverride? = nil
    @ObservedObject private var viewport: ViewportObservable
    private let pixelTableBridge = PixelTableCursorBridge()

    private static let blinkTickRate: TimeInterval = 0.05
    private static let blinkIntervalDefault: TimeInterval = 1.0

    init(document: DocumentModel,
         toolbarState: ToolbarState,
         toolbarController: FITSToolbarController) {
        self.document = document
        self.toolbarState = toolbarState
        self.toolbarController = toolbarController
        self.viewport = document.viewport
        self._selectedHDU = State(initialValue: document.file.firstImageHDUIndex ?? 0)
    }

    var body: some View {
        // Manual three-column layout (NavigationSplitView would hijack the NSToolbar).
        HStack(spacing: 0) {
            HDUSidebar(file: document.file, selection: $selectedHDU)
                .frame(width: 200)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                if let hdu = document.file.hdus[safe: selectedHDU] {
                    makeImageView(hdu: hdu)
                    StatusBar(
                        hdu: hdu,
                        plane: $selectedPlane,
                        planePlaying: $planePlaying,
                        planeFPS: $planeFPS,
                        cursor: cursor,
                        viewport: viewport
                    )
                } else {
                    ContentUnavailableView(
                        "No HDU to show",
                        systemImage: "photo",
                        description: Text("This file's HDUs are empty or non-displayable (try the Header tab).")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInspector, let hdu = document.file.hdus[safe: selectedHDU] {
                Divider()
                InspectorPanel(
                    header: hdu.header,
                    regions: $regions,
                    imageProvider: { currentImage() },
                    wcsProvider: { WCS(header: hdu.header) }
                )
                    .frame(width: 340)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
            .onReceive(
                Timer.publish(every: Self.blinkTickRate, on: .main, in: .common).autoconnect(),
                perform: tick(_:)
            )
            .onChange(of: selectedHDU) { _, _ in
                // Switching HDUs invalidates any image override (reproject / diff)
                // and resets the cube plane.
                displayOverride = nil
                selectedPlane = 0
                planePlaying = false
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow, phases: .down) { press in
                // Nudge selected region first; fall through to cube plane navigation.
                if selectedRegionIndex != nil {
                    return nudgeSelected(dx: -1, dy: 0, shift: press.modifiers.contains(.shift))
                }
                guard let hdu = document.file.hdus[safe: selectedHDU],
                      hdu.planeCount > 1 else { return .ignored }
                selectedPlane = (selectedPlane - 1 + hdu.planeCount) % hdu.planeCount
                return .handled
            }
            .onKeyPress(.rightArrow, phases: .down) { press in
                if selectedRegionIndex != nil {
                    return nudgeSelected(dx: 1, dy: 0, shift: press.modifiers.contains(.shift))
                }
                guard let hdu = document.file.hdus[safe: selectedHDU],
                      hdu.planeCount > 1 else { return .ignored }
                selectedPlane = (selectedPlane + 1) % hdu.planeCount
                return .handled
            }
            .onKeyPress(.space) {
                guard let hdu = document.file.hdus[safe: selectedHDU],
                      hdu.planeCount > 1 else { return .ignored }
                planePlaying.toggle()
                return .handled
            }
            .onKeyPress(.delete) { deleteSelectedRegion() }
            .onKeyPress(.deleteForward) { deleteSelectedRegion() }
            .onKeyPress(.escape) {
                if selectedRegionIndex != nil { selectedRegionIndex = nil; return .handled }
                if profileGeometry != nil { profileGeometry = nil; return .handled }
                return .ignored
            }
            .onKeyPress(.upArrow,    phases: .down) { nudgeSelected(dx: 0,  dy:  1, shift: $0.modifiers.contains(.shift)) }
            .onKeyPress(.downArrow,  phases: .down) { nudgeSelected(dx: 0,  dy: -1, shift: $0.modifiers.contains(.shift)) }
            .onKeyPress("d", phases: .down) {
                guard $0.modifiers.contains(.command) else { return .ignored }
                return duplicateSelectedRegion()
            }
            .background(
                KeyEventMonitor { event in
                    // Only intercept plain space (no modifiers, no text input focused)
                    let isSpace = event.charactersIgnoringModifiers == " "
                    let noMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                    let inTextEditor = (NSApp.keyWindow?.firstResponder as? NSText) != nil
                    guard isSpace, noMods, !inTextEditor,
                          let hdu = document.file.hdus[safe: selectedHDU],
                          hdu.planeCount > 1 else { return event }
                    planePlaying.toggle()
                    return nil   // consume
                }
            )
            .onAppear {
                loadSessionIfPresent()
                syncToolbarState()
                document.regionsBridge = regions
                document.setRegions = { regs in regions = regs }
                document.currentImageProvider = { currentImage() }
            }
            .onChange(of: regions) { _, new in document.regionsBridge = new }
            .background(
                SessionAutosaveWatcher(
                    regions: regions, stretch: stretch, colorMap: colorMap, drawMode: drawMode,
                    showWCSGrid: showWCSGrid, showCompass: showCompass, showColorBar: showColorBar,
                    selectedHDU: selectedHDU, selectedPlane: selectedPlane,
                    contourEnabled: contourSpec.enabled, contourCount: contourSpec.count,
                    save: scheduleSessionSave
                )
            )
            // Collapse 11 toolbar-trigger .onChange entries into a single
            // snapshot-driven .onChange. Cuts the SwiftUI type-checker load
            // on this body and centralises the dependency list.
            .onChange(of: toolbarSyncSnapshot) { _, _ in syncToolbarState() }
            .onChange(of: selectedHDU)   { _, _ in recomputeContours() }
            .onChange(of: selectedPlane) { _, _ in recomputeContours() }
    }

    /// Aggregate of every value that should trigger a toolbar refresh. Hashable
    /// so SwiftUI's diff fires when *any* component changes.
    private var toolbarSyncSnapshot: ToolbarSyncSnapshot {
        ToolbarSyncSnapshot(
            stretch: stretch,
            colorMap: colorMap,
            drawMode: drawMode,
            showWCSGrid: showWCSGrid,
            showCompass: showCompass,
            showColorBar: showColorBar,
            blinking: blinkState != nil,
            fetchingCatalog: isFetchingCatalog,
            selectedHDU: selectedHDU,
            hasDisplayOverride: displayOverride != nil,
            wcsVariant: activeWCSVariant
        )
    }
}

private struct ToolbarSyncSnapshot: Hashable {
    let stretch: ImageStretch
    let colorMap: ColorMap
    let drawMode: DrawMode
    let showWCSGrid: Bool
    let showCompass: Bool
    let showColorBar: Bool
    let blinking: Bool
    let fetchingCatalog: Bool
    let selectedHDU: Int
    let hasDisplayOverride: Bool
    let wcsVariant: String
}

struct HDUSidebar: View {
    let file: FITSFile
    @Binding var selection: Int

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(file.hdus.enumerated()), id: \.offset) { idx, hdu in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("HDU \(idx)").font(.headline)
                        if let name = hdu.name {
                            Text(name)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(hdu.kindLabel) · \(hdu.shapeDescription) · \(hdu.bitpixLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(idx)
            }
        }
        .navigationTitle("HDUs")
    }
}

struct StatusBar: View {
    let hdu: FITSHDU
    @Binding var plane: Int
    @Binding var planePlaying: Bool
    @Binding var planeFPS: Double
    let cursor: CursorInfo?
    @ObservedObject var viewport: ViewportObservable

    /// Persisted readout frame (shared across windows/sessions).
    @AppStorage("readoutFrame") private var coordFrameRaw = CelestialFrame.icrs.rawValue
    private var coordFrame: CelestialFrame { CelestialFrame(rawValue: coordFrameRaw) ?? .icrs }

    private var wcs: WCS? { WCS(header: hdu.header) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullBar
            compactBar
        }
        .font(.body)
        .frame(height: 22)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.accent.opacity(0.6))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var planePicker: some View {
        if hdu.planeCount > 1 {
            CubePlaneControl(
                plane: $plane,
                planeCount: hdu.planeCount,
                playing: $planePlaying,
                fps: $planeFPS
            )
            Divider().frame(height: 14)
        }
    }

    private var fullBar: some View {
        HStack(spacing: 12) {
            planePicker
            pixelBlock(showLabel: true)
            skyBlock
            Spacer(minLength: 12)
            scaleBlock(showLabel: true)
            Text("\(hdu.shapeDescription) · \(hdu.bitpixLabel)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var compactBar: some View {
        HStack(spacing: 10) {
            planePicker
            pixelBlock(showLabel: false)
            skyBlock
            Spacer(minLength: 8)
            scaleBlock(showLabel: false)
        }
    }

    private func pixelBlock(showLabel: Bool) -> some View {
        HStack(spacing: 4) {
            if showLabel { Text("Pixel").foregroundStyle(.tertiary) }
            if let c = cursor {
                Text("(\(c.imageX), \(c.imageY))").font(.system(.body, design: .monospaced))
                Text("=").foregroundStyle(.secondary)
                Text(c.value.isNaN ? "NaN" : String(format: "%.4g", c.value))
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("(—, —) = —")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var skyBlock: some View {
        if let c = cursor, let wcs, let sky = wcs.pixelToSky(imageX: c.imageX, imageY: c.imageY) {
            Divider().frame(height: 14)
            // Project the native-frame (ra,dec) into the user-selected frame.
            let out = CelestialTransform.convert(lon: sky.ra, lat: sky.dec,
                                                 from: wcs.nativeFrame, to: coordFrame)
            let f = SkyCoordinateFormatter.format(lon: out.lon, lat: out.lat, frame: coordFrame)
            Text("\(f.lonLabel) \(f.lon)")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Text("\(f.latLabel) \(f.lat)")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            coordFrameMenu
        }
    }

    /// Lets the user pick the readout frame (DS9-style); persisted across windows.
    private var coordFrameMenu: some View {
        Menu(coordFrame.label) {
            ForEach(CelestialFrame.allCases, id: \.self) { frame in
                Button {
                    coordFrameRaw = frame.rawValue
                } label: {
                    if frame == coordFrame { Label(frame.label, systemImage: "checkmark") }
                    else { Text(frame.label) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Coordinate system for the sky readout")
    }

    private func scaleBlock(showLabel: Bool) -> some View {
        HStack(spacing: 4) {
            if showLabel { Text("Scale").foregroundStyle(.secondary) }
            Text("min").foregroundStyle(.tertiary)
            Text(formatLevel(viewport.vmin))
                .font(.system(.body, design: .monospaced))
            Text("max").foregroundStyle(.tertiary)
            Text(formatLevel(viewport.vmax))
                .font(.system(.body, design: .monospaced))
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
        }
        .lineLimit(1)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .hoverTooltip("Right-click + drag on the image to adjust scale. Horizontal = contrast, vertical = bias. ZScale toolbar button resets.")
    }

    private func formatLevel(_ v: Float) -> String {
        String(format: abs(v) < 1000 && abs(v) >= 0.01 ? "%.3g" : "%.2e", v)
    }
}

struct FITSImageView: View {
    let hdu: FITSHDU
    let plane: Int
    let displayOverride: DisplayOverride?
    let stretch: ImageStretch
    let colorMap: ColorMap
    let viewport: ViewportObservable
    let showWCSGrid: Bool
    let showCompass: Bool
    let showColorBar: Bool
    let contourSegments: [Contours.LeveledSegments]
    let drawMode: DrawMode
    let regions: [Region]
    let selectedRegionIndex: Int?
    let previewRegion: Region?
    let resetLevelsTrigger: Int
    let onCursorChange: (CursorInfo?) -> Void
    let onRegionCreated: (Region) -> Void
    let onRegionPreview: (Region?) -> Void
    let onRegionEdited: (Int, Region) -> Void
    let onRegionSelected: (Int?) -> Void
    let onLineProfile: (SIMD2<Double>, SIMD2<Double>) -> Void
    let onRadialProfile: (SIMD2<Double>, Double) -> Void
    let onGrowthCurve: (SIMD2<Double>, Double) -> Void
    let onMeasure: (SIMD2<Double>, SIMD2<Double>) -> Void
    let onCubeSpectrumAt: (SIMD2<Double>) -> Void
    let onRegionContextMenu: (Int, NSEvent) -> Void
    let onProfileDragPreview: (((SIMD2<Double>, Double, DrawMode)?) -> Void)
    let activeVariant: String
    let remoteCrosshair: SIMD2<Double>?
    let profileGeometry: ProfileGeometry?

    private var resolved: (image: FITSImage, wcs: WCS?)? {
        if let o = displayOverride {
            return (o.image, o.wcs)
        }
        guard hdu.isImage, hdu.naxis >= 2,
              let image = try? FITSImage(hdu: hdu, plane: plane) else { return nil }
        return (image, WCS(header: hdu.header, variant: activeVariant))
    }

    var body: some View {
        if hdu.isTable, let table = FITSTableLoader.load(hdu) {
            TableExtensionView(table: table)
        } else if let resolved {
            let image = resolved.image
            let wcs = resolved.wcs
            ZStack {
                FITSMetalView(
                    image: image,
                    stretch: stretch,
                    colorMap: colorMap,
                    viewport: viewport,
                    drawMode: drawMode,
                    resetLevelsTrigger: resetLevelsTrigger,
                    regions: regions,
                    wcs: wcs,
                    onCursorChange: onCursorChange,
                    onRegionCreated: onRegionCreated,
                    onRegionPreview: onRegionPreview,
                    onRegionEdited: onRegionEdited,
                    onRegionSelected: onRegionSelected,
                    onLineProfile: onLineProfile,
                    onRadialProfile: onRadialProfile,
                    onGrowthCurve: onGrowthCurve,
                    onMeasure: onMeasure,
                    onCubeSpectrumAt: onCubeSpectrumAt,
                    onRegionContextMenu: onRegionContextMenu,
                    onProfileDragPreview: onProfileDragPreview
                )
                if showWCSGrid, let wcs {
                    WCSGridOverlay(image: image, wcs: wcs, viewport: viewport)
                }
                let allRegions = regions + (previewRegion.map { [$0] } ?? [])
                if !allRegions.isEmpty {
                    RegionOverlay(regions: allRegions, selectedIndex: selectedRegionIndex, wcs: wcs, viewport: viewport)
                }
                if showCompass, let wcs {
                    CompassScaleBarOverlay(wcs: wcs, viewport: viewport)
                }
                if !contourSegments.isEmpty {
                    ContourOverlay(leveled: contourSegments, imageHeight: image.height, viewport: viewport)
                }
                CrosshairOverlay(imagePoint: remoteCrosshair, viewport: viewport)
                ProfileGeometryOverlay(geometry: profileGeometry, viewport: viewport)
                if showColorBar {
                    ColorBarOverlay(colorMap: colorMap, viewport: viewport)
                }
                if AppConfig.isBeta {
                    BetaWatermarkOverlay()
                }
            }
        } else {
            ContentUnavailableView(
                "Nothing to render here",
                systemImage: "questionmark.square.dashed",
                description: Text("This HDU doesn't have 2D image data or a parseable table. Open the Header tab to see what's inside.")
            )
        }
    }
}

/// A small, non-interactive "BETA" badge pinned to the top-trailing corner of the
/// image view. Visible only when `AppConfig.isBeta` is true.
struct BetaWatermarkOverlay: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Text("BETA")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        AppTheme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(AppTheme.accent.opacity(0.35), lineWidth: 0.5)
                    )
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

struct InspectorPanel: View {
    let header: FITSHeader
    @Binding var regions: [Region]
    let imageProvider: () -> FITSImage?
    let wcsProvider: () -> WCS?
    @State private var tab: Tab = .header

    enum Tab: String, CaseIterable, Identifiable {
        case header = "Header"
        case regions = "Regions"
        case photometry = "Photometry"
        case stats = "Stats"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)
            switch tab {
            case .header: HeaderPanel(header: header, imageProvider: imageProvider)
            case .regions: RegionListPanel(regions: $regions)
            case .photometry: PhotometryPanel(regions: regions,
                                              imageProvider: imageProvider,
                                              wcsProvider: wcsProvider)
            case .stats: ImageStatsPanel(imageProvider: imageProvider)
            }
        }
    }
}

struct RegionListPanel: View {
    @Binding var regions: [Region]
    @State private var expanded: Set<Int> = []
    @State private var showLoadPanel = false
    @State private var showSavePanel = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    showLoadPanel = true
                } label: { Label("Load…", systemImage: "tray.and.arrow.down") }
                Button {
                    showSavePanel = true
                } label: { Label("Save…", systemImage: "tray.and.arrow.up") }
                    .disabled(regions.isEmpty)
                Spacer()
                if !regions.isEmpty {
                    Button(role: .destructive) {
                        regions.removeAll()
                        expanded.removeAll()
                    } label: { Label("Clear", systemImage: "trash") }
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            content
        }
        .fileImporter(isPresented: $showLoadPanel,
                      allowedContentTypes: [.plainText, .data],
                      allowsMultipleSelection: false) { result in
            handleLoad(result)
        }
        .fileExporter(isPresented: $showSavePanel,
                      document: RegionDocument(regions: regions),
                      contentType: .plainText,
                      defaultFilename: "regions.reg") { _ in }
    }

    @ViewBuilder
    private var content: some View {
        if regions.isEmpty {
            ContentUnavailableView(
                "Nothing marked yet",
                systemImage: "circle.dashed",
                description: Text("Pick a shape in the toolbar's Mode menu and drag on the image to mark a star, source, or region — or Load… an existing .reg file.")
            )
        } else {
            List {
                ForEach(Array(regions.enumerated()), id: \.offset) { idx, region in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button {
                                if expanded.contains(idx) { expanded.remove(idx) } else { expanded.insert(idx) }
                            } label: {
                                Image(systemName: expanded.contains(idx) ? "chevron.down" : "chevron.right")
                                    .frame(width: 12)
                            }
                            .buttonStyle(.borderless)
                            Image(systemName: icon(for: region))
                            Text(describe(region))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                regions.remove(at: idx)
                                expanded.remove(idx)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        if expanded.contains(idx) {
                            RegionEditor(region: Binding(
                                get: { regions[idx] },
                                set: { regions[idx] = $0 }
                            ))
                            .padding(.leading, 22)
                        }
                    }
                }
            }
        }
    }

    private func icon(for r: Region) -> String {
        switch r.shape {
        case .circle: return "circle"
        case .box: return "rectangle"
        case .ellipse: return "oval"
        case .polygon: return "hexagon"
        case .annulus: return "circle.dotted.circle"
        case .point: return "smallcircle.filled.circle"
        }
    }

    private func describe(_ r: Region) -> String {
        switch r.shape {
        case .circle(let c, let radius):
            return "circle (\(fmt(c.x)), \(fmt(c.y))) r=\(fmt(radius.value))"
        case .box(let c, let w, let h, let a):
            return "box (\(fmt(c.x)), \(fmt(c.y))) \(fmt(w.value))×\(fmt(h.value))∠\(fmt(a))"
        case .ellipse(let c, let rx, let ry, let a):
            return "ellipse (\(fmt(c.x)), \(fmt(c.y))) rx=\(fmt(rx.value)) ry=\(fmt(ry.value))∠\(fmt(a))"
        case .annulus(let c, let rIn, let rOut):
            return "annulus (\(fmt(c.x)), \(fmt(c.y))) \(fmt(rIn.value))…\(fmt(rOut.value))"
        case .polygon(let pts):
            return "polygon (\(pts.count) verts)"
        case .point(let p):
            return "point (\(fmt(p.x)), \(fmt(p.y)))"
        }
    }

    private func fmt(_ d: Double) -> String { String(format: "%.1f", d) }

    private func handleLoad(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let loaded = try? RegionFile.parse(text) else { return }
        regions = loaded
    }
}

struct HeaderPanel: View {
    let header: FITSHeader
    let imageProvider: () -> FITSImage?
    @State private var search: String = ""
    @State private var edits: [Int: (value: String, comment: String)] = [:]
    @State private var editing: Bool = false

    struct Row: Identifiable {
        let id: Int
        let card: FITSHeader.Card
    }

    var rows: [Row] {
        let all = header.cards.enumerated().map { Row(id: $0.offset, card: $0.element) }
        guard !search.isEmpty else { return all }
        let q = search.lowercased()
        return all.filter { row in
            let c = row.card
            if c.keyword.lowercased().contains(q) { return true }
            if let v = c.value?.displayString.lowercased(), v.contains(q) { return true }
            if let cmt = c.comment?.lowercased(), cmt.contains(q) { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter…", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Edit", isOn: $editing).toggleStyle(.button).controlSize(.small)
                Button {
                    saveEditedFITS()
                } label: { Label("Save modified…", systemImage: "tray.and.arrow.up") }
                .controlSize(.small)
                .disabled(edits.isEmpty)
            }
            .padding(8)
            if editing {
                List(rows) { row in
                    HStack(spacing: 8) {
                        Text(row.card.keyword)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 70, alignment: .leading)
                        TextField("value", text: valueBinding(for: row))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 160)
                        TextField("comment", text: commentBinding(for: row))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(edits[row.id] != nil ? .primary : .secondary)
                    }
                }
            } else {
                Table(rows) {
                    TableColumn("Keyword") { row in
                        Text(row.card.keyword).font(.system(.body, design: .monospaced))
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Value") { row in
                        Text(row.card.value?.displayString ?? "")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    TableColumn("Comment") { row in
                        Text(row.card.comment ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            if !edits.isEmpty {
                Text("\(edits.count) edited card\(edits.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    private func valueBinding(for row: Row) -> Binding<String> {
        Binding(
            get: { edits[row.id]?.value ?? row.card.value?.displayString ?? "" },
            set: { v in
                let c = edits[row.id]?.comment ?? row.card.comment ?? ""
                edits[row.id] = (v, c)
            }
        )
    }

    private func commentBinding(for row: Row) -> Binding<String> {
        Binding(
            get: { edits[row.id]?.comment ?? row.card.comment ?? "" },
            set: { c in
                let v = edits[row.id]?.value ?? row.card.value?.displayString ?? ""
                edits[row.id] = (v, c)
            }
        )
    }

    private func saveEditedFITS() {
        guard let image = imageProvider() else { NSSound.beep(); return }
        // Build extraCards from all cards (with edits applied), skipping the structural
        // ones FITSWriter writes itself.
        let skip: Set<String> = ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "NAXIS3", "END"]
        var extra: [String] = []
        for (idx, card) in header.cards.enumerated() {
            if skip.contains(card.keyword) { continue }
            let edited = edits[idx]
            let valueText = edited?.value ?? card.value?.displayString ?? ""
            let commentText = edited?.comment ?? card.comment ?? ""
            if let serialized = FITSHeader.serializeCard(
                keyword: card.keyword, valueText: valueText, commentText: commentText
            ) {
                extra.append(serialized)
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fits") ?? .data]
        panel.nameFieldStringValue = "modified.fits"
        guard let win = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try FITSWriter.write(image, to: url, extraCards: extra)
                edits.removeAll()
            } catch {
                let a = NSAlert(error: error)
                a.runModal()
            }
        }
    }
}

extension Array {
    subscript(safe idx: Int) -> Element? {
        indices.contains(idx) ? self[idx] : nil
    }
}

struct DisplayOverride: Equatable {
    let image: FITSImage
    let wcs: WCS?
    let label: String

    static func == (lhs: DisplayOverride, rhs: DisplayOverride) -> Bool {
        lhs.label == rhs.label
    }
}

extension DocumentView {
    fileprivate func syncToolbarState() {
        toolbarState.stretch = stretch
        toolbarState.colorMap = colorMap
        toolbarState.drawMode = drawMode
        toolbarState.showWCSGrid = showWCSGrid
        toolbarState.showCompass = showCompass
        toolbarState.showColorBar = showColorBar
        toolbarState.blinkActive = blinkState != nil
        toolbarState.isFetchingCatalog = isFetchingCatalog
        let selected = document.file.hdus[safe: selectedHDU]
        toolbarState.hasSelectedImage = selected != nil
        toolbarState.hasWCS = selected.flatMap { WCS(header: $0.header, variant: activeWCSVariant) } != nil
        if let hdu = selected {
            let variants = WCS.availableVariants(in: hdu.header)
            toolbarState.wcsVariants = variants
            var labels: [String: String] = [:]
            for v in variants {
                if let name = hdu.header["WCSNAME\(v)"]?.stringValue { labels[v] = name }
            }
            toolbarState.wcsVariantLabels = labels
            if !variants.contains(activeWCSVariant), let first = variants.first {
                activeWCSVariant = first
            }
            toolbarState.activeWCSVariant = activeWCSVariant
        }
        toolbarState.hasMultipleHDUs = document.file.hdus.count >= 2
        toolbarState.hasCube = (selected?.naxis == 3)
        toolbarState.hasDisplayOverride = displayOverride != nil

        let candidates = otherImageHDUIndices()
        toolbarState.reprojectCandidates = candidates.map { ($0, hduLabel($0), canReproject(onto: $0)) }
        toolbarState.differenceCandidates = candidates.map { ($0, hduLabel($0), canDifference(against: $0)) }

        toolbarState.onSelectStretch    = { v in stretch = v }
        toolbarState.onSelectMap        = { v in colorMap = v }
        toolbarState.onSelectMode       = { v in drawMode = v }
        toolbarState.onZScale           = { resetLevelsTrigger &+= 1 }
        toolbarState.onExport           = { exportImage() }
        toolbarState.onToggleGrid       = { showWCSGrid.toggle() }
        toolbarState.onToggleCompass    = { showCompass.toggle() }
        toolbarState.onToggleColorBar   = { showColorBar.toggle() }
        toolbarState.onToggleBlink      = { toggleBlink() }
        toolbarState.onReproject        = { reproject(onto: $0) }
        toolbarState.onDifference       = { computeDifference(against: $0) }
        toolbarState.onClearOverride    = { displayOverride = nil }
        toolbarState.onFetchCatalog     = { Task { await fetchCatalog() } }
        toolbarState.onToggleInspector  = { showInspector.toggle() }
        toolbarState.onOpenScaleParameters = { openScaleParametersPanel() }
        toolbarState.onOpenPixelTable = {
            PixelTableWindowController.show(
                provider: { currentImage() },
                cursorPublisher: pixelTableBridge,
                attachedTo: NSApp.keyWindow
            )
        }
        toolbarState.onOpenContourLevels = { openContourLevelsPanel() }
        toolbarState.onCollapseCube = { mode in collapseCube(mode) }
        toolbarState.onDetectSources = { detectSourcesAndAddRegions() }
        toolbarState.onCropToSelection = { cropToSelectedRegion() }
        toolbarState.onSelectWCSVariant = { v in activeWCSVariant = v }
        toolbarState.onExportCubeMP4 = { exportCubeAsMP4() }
        toolbarState.onSubtractBackground = { subtractBackground() }
        toolbarState.onBinImage = { n in binImage(by: n) }
        toolbarState.onCubeSlab = { _, _ in promptForSlab() }
        toolbarState.onStackOpenDocuments = { mode in stackOpenDocuments(mode: mode) }
        toolbarState.onLightCurve = { generateLightCurve() }
        toolbarState.onApplyFilter = { spec in applyFilter(spec) }
        toolbarState.onApplyUnary = { op in applyUnary(op) }
        toolbarState.onApplyBinary = { op, idx in applyBinary(op, other: idx) }
        toolbarState.onApplyScalePreset = { preset in applyScalePreset(preset) }
    }

    @ViewBuilder
    fileprivate func makeImageView(hdu: FITSHDU) -> some View {
        FITSImageView(
            hdu: hdu,
            plane: selectedPlane,
            displayOverride: displayOverride,
            stretch: stretch,
            colorMap: colorMap,
            viewport: viewport,
            showWCSGrid: showWCSGrid,
            showCompass: showCompass,
            showColorBar: showColorBar,
            contourSegments: contourSpec.enabled ? contourSegments : [],
            drawMode: drawMode,
            regions: regions,
            selectedRegionIndex: selectedRegionIndex,
            previewRegion: previewRegion,
            resetLevelsTrigger: resetLevelsTrigger,
            onCursorChange: handleCursor,
            onRegionCreated: appendRegion,
            onRegionPreview: { previewRegion = $0 },
            onRegionEdited: updateRegion,
            onRegionSelected: { selectedRegionIndex = $0 },
            onLineProfile: { from, to in handleLineProfile(from: from, to: to) },
            onRadialProfile: { center, r in handleRadialProfile(center: center, radius: r) },
            onGrowthCurve: { center, r in handleGrowthCurve(center: center, radius: r) },
            onMeasure: { from, to in handleMeasure(from: from, to: to) },
            onCubeSpectrumAt: { p in handleCubeSpectrum(at: p) },
            onRegionContextMenu: { idx, event in showRegionContextMenu(index: idx, event: event) },
            onProfileDragPreview: { preview in handleProfileDragPreview(preview) },
            activeVariant: activeWCSVariant,
            remoteCrosshair: document.remoteCrosshair,
            profileGeometry: profileGeometry
        )
    }

    private func handleLineProfile(from: SIMD2<Double>, to: SIMD2<Double>) {
        guard let hdu = document.file.hdus[safe: selectedHDU] else { return }
        let dx = to.x - from.x, dy = to.y - from.y
        let len = (dx * dx + dy * dy).squareRoot()
        let n = max(64, Int(len.rounded(.up)) * 2)
        profileGeometry = .line(from: from, to: to)
        if hdu.naxis == 3 {
            guard let pv = try? Profiles.pvDiagram(hdu: hdu, from: (from.x, from.y), to: (to.x, to.y), samples: n) else { return }
            PVDiagramWindowController.show(image: pv, imageName: document.url.lastPathComponent, attachedTo: NSApp.keyWindow)
            return
        }
        guard let image = currentImage() else { return }
        let samples = Profiles.lineProfile(image: image, from: (from.x, from.y), to: (to.x, to.y),
                                           samples: n, interpolation: .bilinear)
        LineProfileWindowController.show(samples: samples, imageName: document.url.lastPathComponent, attachedTo: NSApp.keyWindow)
    }

    private func handleRadialProfile(center: SIMD2<Double>, radius: Double) {
        guard let image = currentImage() else { return }
        let maxR = radius > 0 ? radius : Double(min(image.width, image.height)) / 2
        profileGeometry = .radial(center: center, maxRadius: maxR)
        RadialProfileWindowController.show(
            image: image,
            center: center,
            initialRadius: maxR,
            imageName: document.url.lastPathComponent,
            attachedTo: NSApp.keyWindow,
            onRadiusChange: { newR in profileGeometry = .radial(center: center, maxRadius: newR) }
        )
    }

    private func handleProfileDragPreview(_ preview: (SIMD2<Double>, Double, DrawMode)?) {
        guard let preview else { return }
        let (center, radius, mode) = preview
        if mode == .radialProfile {
            profileGeometry = .radial(center: center, maxRadius: radius)
        } else if mode == .growthCurve {
            profileGeometry = .growth(center: center, maxRadius: radius)
        }
    }

    private func handleMeasure(from: SIMD2<Double>, to: SIMD2<Double>) {
        let dx = to.x - from.x, dy = to.y - from.y
        let pixelDist = (dx * dx + dy * dy).squareRoot()
        var lines = [String(format: "Pixel distance: %.2f px", pixelDist)]
        if let hdu = document.file.hdus[safe: selectedHDU],
           let wcs = WCS(header: hdu.header, variant: activeWCSVariant),
           let s = wcs.pixelToSky(imageX: Int(from.x.rounded()), imageY: Int(from.y.rounded())),
           let e = wcs.pixelToSky(imageX: Int(to.x.rounded()), imageY: Int(to.y.rounded())) {
            let arcsec = haversineArcsec(ra1: s.ra, dec1: s.dec, ra2: e.ra, dec2: e.dec)
            let pa = positionAngleDeg(ra1: s.ra, dec1: s.dec, ra2: e.ra, dec2: e.dec)
            if arcsec < 60 {
                lines.append(String(format: "Sky distance: %.3f″", arcsec))
            } else if arcsec < 3600 {
                lines.append(String(format: "Sky distance: %.3f′ (%.2f″)", arcsec / 60, arcsec))
            } else {
                lines.append(String(format: "Sky distance: %.4f° (%.2f′)", arcsec / 3600, arcsec / 60))
            }
            lines.append(String(format: "Position angle: %.2f° (E of N)", pa))
        }
        let alert = NSAlert()
        alert.messageText = "Measurement"
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func haversineArcsec(ra1: Double, dec1: Double, ra2: Double, dec2: Double) -> Double {
        let r1 = ra1 * .pi / 180, d1 = dec1 * .pi / 180
        let r2 = ra2 * .pi / 180, d2 = dec2 * .pi / 180
        let dlon = r2 - r1, dlat = d2 - d1
        let a = sin(dlat / 2) * sin(dlat / 2) + cos(d1) * cos(d2) * sin(dlon / 2) * sin(dlon / 2)
        let c = 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
        return c * 180 / .pi * 3600
    }

    private func positionAngleDeg(ra1: Double, dec1: Double, ra2: Double, dec2: Double) -> Double {
        let r1 = ra1 * .pi / 180, d1 = dec1 * .pi / 180
        let r2 = ra2 * .pi / 180, d2 = dec2 * .pi / 180
        let dlon = r2 - r1
        let y = sin(dlon) * cos(d2)
        let x = cos(d1) * sin(d2) - sin(d1) * cos(d2) * cos(dlon)
        var pa = atan2(y, x) * 180 / .pi
        if pa < 0 { pa += 360 }
        return pa
    }

    private func handleGrowthCurve(center: SIMD2<Double>, radius: Double) {
        guard let image = currentImage() else { return }
        let maxR = radius > 0 ? radius : min(Double(image.width), Double(image.height)) / 2
        profileGeometry = .growth(center: center, maxRadius: maxR)
        GrowthCurveWindowController.show(
            image: image,
            center: center,
            initialRadius: maxR,
            imageName: document.url.lastPathComponent,
            attachedTo: NSApp.keyWindow,
            onRadiusChange: { newR in profileGeometry = .growth(center: center, maxRadius: newR) }
        )
    }

    private func handleCubeSpectrum(at p: SIMD2<Double>) {
        guard let hdu = document.file.hdus[safe: selectedHDU], hdu.naxis == 3 else { return }
        profileGeometry = .point(p)
        let wcs = WCS(header: hdu.header, variant: activeWCSVariant)
        let axis = SpectralAxis(header: hdu.header)
        let xs = axis?.values(planeCount: hdu.planeCount)
        let xLabel = axis?.axisLabel ?? "plane"
        let hit = RegionHitTest.hit(in: regions, atImagePoint: p, toleranceImagePixels: 4, wcs: wcs)
        if let h = hit, regions.indices.contains(h.regionIndex),
           let values = try? Profiles.cubeSpectrum(hdu: hdu, region: regions[h.regionIndex], wcs: wcs, combine: .sum) {
            CubeSpectrumWindowController.show(values: values, currentPlane: selectedPlane,
                                              label: "region #\(h.regionIndex) (sum)",
                                              attachedTo: NSApp.keyWindow, xValues: xs, xLabel: xLabel)
            return
        }
        let pixel = (Int(p.x.rounded()), Int(p.y.rounded()))
        guard let values = try? Profiles.cubeSpectrum(hdu: hdu, atPixel: pixel) else { return }
        CubeSpectrumWindowController.show(values: values, currentPlane: selectedPlane,
                                          label: "pixel (\(pixel.0), \(pixel.1))",
                                          attachedTo: NSApp.keyWindow, xValues: xs, xLabel: xLabel)
    }

    private func handleCursor(_ info: CursorInfo?) {
        cursor = info
        pixelTableBridge.cursor = info
        // Broadcast for crosshair sync.
        if let info, let parent = AppDelegate.shared?.controllerForCurrentDocument(matching: document.url) {
            let wcs = document.file.hdus[safe: selectedHDU].flatMap { WCS(header: $0.header, variant: activeWCSVariant) }
            WindowSyncCoordinator.shared.broadcastCursor(
                imagePoint: SIMD2(Double(info.imageX), Double(info.imageY)),
                from: parent, sourceWCS: wcs
            )
        }
    }

    private func appendRegion(_ r: Region) {
        // Apply the user's default colour preference when the region was created
        // without any explicit attributes (drag-on-canvas path).
        var attrs = r.attributes
        if attrs["color"] == nil {
            attrs["color"] = UserPreferences.shared.regionColor
        }
        let withColor = Region(shape: r.shape, frame: r.frame, attributes: attrs)
        regions.append(withColor)
        selectedRegionIndex = regions.count - 1
    }

    private func updateRegion(idx: Int, region: Region) {
        guard regions.indices.contains(idx) else { return }
        regions[idx] = region
    }

    fileprivate func tick(_ now: Date) {
        if let bs = blinkState {
            let target = bs.currentHDU(at: now)
            if selectedHDU != target { selectedHDU = target }
        }
        guard planePlaying,
              let hdu = document.file.hdus[safe: selectedHDU],
              hdu.planeCount > 1,
              now.timeIntervalSince(lastPlaneAdvance) >= 1.0 / planeFPS else { return }
        selectedPlane = (selectedPlane + 1) % hdu.planeCount
        lastPlaneAdvance = now
    }

    fileprivate func showRegionContextMenu(index: Int, event: NSEvent) {
        guard regions.indices.contains(index), let view = NSApp.keyWindow?.contentView else { return }
        selectedRegionIndex = index
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Duplicate") {
            _ = duplicateSelectedRegion()
        })
        menu.addItem(makeMenuItem("Delete") {
            regions.remove(at: index)
            selectedRegionIndex = nil
        })
        menu.addItem(makeMenuItem("Bring to front") {
            let r = regions.remove(at: index)
            regions.append(r)
            selectedRegionIndex = regions.count - 1
        })
        menu.addItem(.separator())
        // Copy as .reg text.
        menu.addItem(makeMenuItem("Copy as .reg text") {
            let text = RegionFile.format([regions[index]])
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        })
        // Submenu: color
        let colorMenu = NSMenu()
        for c in ["green", "red", "yellow", "cyan", "magenta", "blue", "white"] {
            colorMenu.addItem(makeMenuItem(c.capitalized) {
                var attrs = regions[index].attributes
                attrs["color"] = c
                regions[index] = Region(shape: regions[index].shape, frame: regions[index].frame, attributes: attrs)
            })
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func makeMenuItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, action: action)
    }

    fileprivate func deleteSelectedRegion() -> KeyPress.Result {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx) else { return .ignored }
        regions.remove(at: idx)
        selectedRegionIndex = nil
        return .handled
    }

    fileprivate func nudgeSelected(dx: Int, dy: Int, shift: Bool) -> KeyPress.Result {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx) else { return .ignored }
        let step = shift ? 10.0 : 1.0
        let region = regions[idx]
        let newShape: Region.Shape
        switch region.shape {
        case .circle(let c, let r):
            newShape = .circle(center: .init(x: c.x + Double(dx) * step, y: c.y + Double(dy) * step), radius: r)
        case .box(let c, let w, let h, let a):
            newShape = .box(center: .init(x: c.x + Double(dx) * step, y: c.y + Double(dy) * step),
                            width: w, height: h, angle: a)
        case .ellipse(let c, let rx, let ry, let a):
            newShape = .ellipse(center: .init(x: c.x + Double(dx) * step, y: c.y + Double(dy) * step),
                                rx: rx, ry: ry, angle: a)
        case .annulus(let c, let i, let o):
            newShape = .annulus(center: .init(x: c.x + Double(dx) * step, y: c.y + Double(dy) * step),
                                innerRadius: i, outerRadius: o)
        case .polygon(let pts):
            newShape = .polygon(points: pts.map {
                .init(x: $0.x + Double(dx) * step, y: $0.y + Double(dy) * step)
            })
        case .point(let p):
            newShape = .point(.init(x: p.x + Double(dx) * step, y: p.y + Double(dy) * step))
        }
        regions[idx] = Region(shape: newShape, frame: region.frame, attributes: region.attributes)
        return .handled
    }

    fileprivate func duplicateSelectedRegion() -> KeyPress.Result {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx) else { return .ignored }
        let copy = regions[idx]
        // Offset the duplicate by 5 px so it's visible.
        let offset = nudgedRegion(copy, dx: 5, dy: 5)
        regions.append(offset)
        selectedRegionIndex = regions.count - 1
        return .handled
    }

    private func nudgedRegion(_ r: Region, dx: Double, dy: Double) -> Region {
        let shape: Region.Shape
        switch r.shape {
        case .circle(let c, let rad): shape = .circle(center: .init(x: c.x + dx, y: c.y + dy), radius: rad)
        case .box(let c, let w, let h, let a): shape = .box(center: .init(x: c.x + dx, y: c.y + dy), width: w, height: h, angle: a)
        case .ellipse(let c, let rx, let ry, let a): shape = .ellipse(center: .init(x: c.x + dx, y: c.y + dy), rx: rx, ry: ry, angle: a)
        case .annulus(let c, let i, let o): shape = .annulus(center: .init(x: c.x + dx, y: c.y + dy), innerRadius: i, outerRadius: o)
        case .polygon(let pts): shape = .polygon(points: pts.map { .init(x: $0.x + dx, y: $0.y + dy) })
        case .point(let p): shape = .point(.init(x: p.x + dx, y: p.y + dy))
        }
        return Region(shape: shape, frame: r.frame, attributes: r.attributes)
    }

    fileprivate func currentImage() -> FITSImage? {
        guard let hdu = document.file.hdus[safe: selectedHDU] else { return nil }
        let plane = hdu.planeCount > 1 ? selectedPlane : 0
        return try? FITSImage(hdu: hdu, plane: plane)
    }

    fileprivate func snapshotSession() -> SessionState {
        let contour: SessionState.Contour? = SessionState.Contour(
            enabled: contourSpec.enabled,
            count: contourSpec.count,
            minValue: contourSpec.minValue,
            maxValue: contourSpec.maxValue,
            spacing: contourSpec.spacing.rawValue
        )
        return SessionState(
            selectedHDU: selectedHDU,
            selectedPlane: selectedPlane,
            stretch: stretch,
            colorMap: colorMap,
            drawMode: drawMode.rawValue,
            vmin: Double(viewport.vmin),
            vmax: Double(viewport.vmax),
            stretchParameter: Double(viewport.stretchParameter),
            showWCSGrid: showWCSGrid,
            showCompass: showCompass,
            showColorBar: showColorBar,
            regions: regions,
            contour: contour
        )
    }

    fileprivate func scheduleSessionSave() {
        let url = SessionState.sidecarURL(for: document.url)
        guard let data = try? snapshotSession().toJSON() else { return }
        // Fire-and-forget — write atomically. Failures are non-fatal (user shouldn't
        // lose work over a read-only sidecar directory).
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    fileprivate func loadSessionIfPresent() {
        let url = SessionState.sidecarURL(for: document.url)
        guard let data = try? Data(contentsOf: url),
              let session = try? SessionState.fromJSON(data) else {
            // No saved session → trigger one zscale pass so the freshly-opened file
            // looks like data, not a black square.
            resetLevelsTrigger &+= 1
            return
        }
        if document.file.hdus.indices.contains(session.selectedHDU) {
            selectedHDU = session.selectedHDU
        }
        selectedPlane = session.selectedPlane
        stretch = session.stretch
        colorMap = session.colorMap
        if let mode = DrawMode(rawValue: session.drawMode) { drawMode = mode }
        viewport.vmin = Float(session.vmin)
        viewport.vmax = Float(session.vmax)
        viewport.stretchParameter = Float(session.stretchParameter)
        showWCSGrid = session.showWCSGrid
        showCompass = session.showCompass
        showColorBar = session.showColorBar
        regions = session.regions
        if let c = session.contour {
            contourSpec = ContourSpec(
                enabled: c.enabled,
                count: c.count,
                minValue: c.minValue,
                maxValue: c.maxValue,
                spacing: ContourSpec.Spacing(rawValue: c.spacing) ?? .linear
            )
            recomputeContours()
        }
    }

    fileprivate func applyFilter(_ spec: FilterSpec) {
        guard let image = currentImage() else { return }
        let filtered: FITSImage
        switch spec {
        case .boxcar(let n):    filtered = ImageFilters.boxcar(image, size: n)
        case .median(let n):    filtered = ImageFilters.median(image, size: n)
        case .gaussian(let s):  filtered = ImageFilters.gaussian(image, sigma: s)
        }
        let label: String
        switch spec {
        case .boxcar(let n):    label = "Boxcar \(n)×\(n)"
        case .median(let n):    label = "Median \(n)×\(n)"
        case .gaussian(let s):  label = String(format: "Gaussian σ=%.1f", s)
        }
        displayOverride = DisplayOverride(image: filtered,
                                          wcs: document.file.hdus[safe: selectedHDU].flatMap { WCS(header: $0.header) },
                                          label: label)
        resetLevelsTrigger &+= 1
    }

    fileprivate func applyUnary(_ op: ImageArithmetic.UnaryOp) {
        guard let image = currentImage() else { return }
        let transformed = ImageArithmetic.unary(image, op: op)
        displayOverride = DisplayOverride(image: transformed,
                                          wcs: document.file.hdus[safe: selectedHDU].flatMap { WCS(header: $0.header) },
                                          label: op.label)
        resetLevelsTrigger &+= 1
    }

    fileprivate func applyBinary(_ op: ImageArithmetic.BinaryOp, other otherIdx: Int) {
        guard let a = currentImage(),
              let otherHdu = document.file.hdus[safe: otherIdx],
              let b = try? FITSImage(hdu: otherHdu),
              let result = try? ImageArithmetic.combined(a, b, op: op) else { return }
        displayOverride = DisplayOverride(image: result,
                                          wcs: document.file.hdus[safe: selectedHDU].flatMap { WCS(header: $0.header) },
                                          label: "\(op.label) vs HDU \(otherIdx)")
        resetLevelsTrigger &+= 1
    }

    fileprivate func subtractBackground() {
        guard let image = currentImage() else { NSSound.beep(); return }
        let bg = PixelStatistics.sigmaClipped(image.physicalValues(), sigma: 3, iterations: 5)
        // Build a constant-image of the background and subtract.
        let bgImg = FITSImage.fromFloat32(pixels: [Float](repeating: Float(bg.mean),
                                                          count: image.width * image.height),
                                          width: image.width, height: image.height)
        guard let result = try? ImageArithmetic.combined(image, bgImg, op: .difference) else { return }
        displayOverride = DisplayOverride(image: result,
                                          wcs: document.file.hdus[safe: selectedHDU].flatMap { WCS(header: $0.header) },
                                          label: String(format: "BG sub (μ=%.3g, σ=%.3g, n=%d)", bg.mean, bg.stddev, bg.count))
        resetLevelsTrigger &+= 1
    }

    fileprivate func binImage(by n: Int) {
        guard let image = currentImage(), n >= 2 else { NSSound.beep(); return }
        let w = image.width / n, h = image.height / n
        guard w > 0, h > 0 else { return }
        var out = [Float](repeating: 0, count: w * h)
        for by in 0..<h {
            for bx in 0..<w {
                var sum = 0.0
                var cnt = 0
                for j in 0..<n {
                    for i in 0..<n {
                        let v = image.physicalValue(x: bx * n + i, y: by * n + j)
                        if !v.isNaN { sum += v; cnt += 1 }
                    }
                }
                out[by * w + bx] = cnt > 0 ? Float(sum / Double(cnt)) : .nan
            }
        }
        let result = FITSImage.fromFloat32(pixels: out, width: w, height: h)
        displayOverride = DisplayOverride(image: result, wcs: nil, label: "Binned \(n)×\(n)")
        resetLevelsTrigger &+= 1
    }

    fileprivate func promptForSlab() {
        guard let hdu = document.file.hdus[safe: selectedHDU], hdu.naxis == 3 else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Extract Cube Slab"
        alert.informativeText = "Sum planes (inclusive) of a \(hdu.planeCount)-plane cube. Enter range:"
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let fromField = NSTextField(string: "0")
        fromField.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        let toField = NSTextField(string: "\(hdu.planeCount - 1)")
        toField.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        stack.addArrangedSubview(NSTextField(labelWithString: "From"))
        stack.addArrangedSubview(fromField)
        stack.addArrangedSubview(NSTextField(labelWithString: "To"))
        stack.addArrangedSubview(toField)
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let from = max(0, min(hdu.planeCount - 1, Int(fromField.stringValue) ?? 0))
            let to   = max(0, min(hdu.planeCount - 1, Int(toField.stringValue) ?? hdu.planeCount - 1))
            extractCubeSlab(from: min(from, to), to: max(from, to))
        }
    }

    private func extractCubeSlab(from: Int, to: Int) {
        guard let hdu = document.file.hdus[safe: selectedHDU], hdu.naxis == 3 else { return }
        let w = hdu.axes[0], h = hdu.axes[1]
        var out = [Float](repeating: 0, count: w * h)
        var cnt = [Int](repeating: 0, count: w * h)
        for p in from...to {
            guard let img = try? FITSImage(hdu: hdu, plane: p) else { continue }
            for y in 0..<h {
                for x in 0..<w {
                    let v = img.physicalValue(x: x, y: y)
                    if v.isNaN { continue }
                    out[y * w + x] += Float(v)
                    cnt[y * w + x] += 1
                }
            }
        }
        for i in 0..<out.count where cnt[i] == 0 { out[i] = .nan }
        let result = FITSImage.fromFloat32(pixels: out, width: w, height: h)
        displayOverride = DisplayOverride(image: result,
                                          wcs: WCS(header: hdu.header),
                                          label: "Slab \(from)…\(to) (sum)")
        resetLevelsTrigger &+= 1
    }

    fileprivate func stackOpenDocuments(mode: StackMode) {
        let allControllers = AppDelegate.shared?.allControllersForScripting() ?? []
        let images: [FITSImage] = allControllers.compactMap { c in c.currentOverrideImage() }
        guard images.count >= 2 else {
            let alert = NSAlert()
            alert.messageText = "Stack requires ≥ 2 open documents"
            alert.informativeText = "Open another FITS file in a second window first."
            alert.runModal()
            return
        }
        // Dimensions must match.
        guard let first = images.first else { return }
        for img in images where img.width != first.width || img.height != first.height {
            let alert = NSAlert()
            alert.messageText = "Dimension mismatch"
            alert.informativeText = "All open images must be the same size to stack. Reproject first."
            alert.runModal()
            return
        }
        let w = first.width, h = first.height
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let y = i / w, x = i % w
            var vals: [Double] = []
            vals.reserveCapacity(images.count)
            for img in images {
                let v = img.physicalValue(x: x, y: y)
                if !v.isNaN { vals.append(v) }
            }
            if vals.isEmpty { out[i] = .nan; continue }
            switch mode {
            case .sum:    out[i] = Float(vals.reduce(0, +))
            case .mean:   out[i] = Float(vals.reduce(0, +) / Double(vals.count))
            case .median: vals.sort(); out[i] = Float(vals[vals.count / 2])
            }
        }
        let result = FITSImage.fromFloat32(pixels: out, width: w, height: h)
        displayOverride = DisplayOverride(image: result, wcs: nil,
                                          label: "Stack \(mode.label) of \(images.count) windows")
        resetLevelsTrigger &+= 1
    }

    fileprivate func generateLightCurve() {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx) else {
            let a = NSAlert()
            a.messageText = "Pick a region first"
            a.informativeText = "Select an aperture region (a circle is typical) before generating a light curve. The region's sky position is reprojected into each open file via WCS."
            a.runModal(); return
        }
        let reference = regions[idx]
        guard let refHDU = document.file.hdus.first(where: { $0.isImage && $0.naxis >= 2 }),
              let refWCS = WCS(header: refHDU.header) else {
            let a = NSAlert()
            a.messageText = "Reference image has no WCS"
            a.informativeText = "Light curves need WCS to project the aperture onto each open document."
            a.runModal(); return
        }
        // Project the region's centre into sky once.
        guard let centre = imageCenter(of: regionCentre(of: reference), frame: reference.frame, wcs: refWCS) else { return }
        guard let sky = refWCS.pixelToSky(imageX: Int(centre.x.rounded()), imageY: Int(centre.y.rounded())) else { return }

        // Sample every open document.
        let controllers = AppDelegate.shared?.allControllersForScripting() ?? []
        var points: [(time: Double, flux: Double, err: Double, label: String)] = []
        var timeLabel = "MJD"
        for c in controllers {
            let model = c.documentModel
            guard let hdu = model.file.hdus.first(where: { $0.isImage && $0.naxis >= 2 }),
                  let img = try? FITSImage(hdu: hdu),
                  let wcs = WCS(header: hdu.header),
                  let p = wcs.skyToPixel(ra: sky.ra, dec: sky.dec) else { continue }
            // Reproject the region to this image's pixel frame as an image-frame copy.
            let projected = reprojectRegion(reference, toImagePixel: (p.x, p.y))
            guard let m = Photometry.measure(region: projected, image: img, wcs: nil) else { continue }
            let flux = m.skySubtractedFlux ?? m.sum
            let err = m.skySubtractedFluxError ?? m.sumError
            if let t = FITSTime.observationMJD(header: hdu.header) {
                points.append((t.mjd, flux, err, model.url.lastPathComponent))
                timeLabel = t.label
            } else {
                // Use index as fake time if no header time.
                points.append((Double(points.count), flux, err, model.url.lastPathComponent))
                timeLabel = "file index"
            }
        }
        if points.count < 2 {
            let a = NSAlert()
            a.messageText = "Need ≥ 2 open documents"
            a.informativeText = "Open more files of the same field, then run Light curve again."
            a.runModal(); return
        }
        points.sort { $0.time < $1.time }
        LightCurveWindowController.show(
            points: points.map { (time: $0.time, flux: $0.flux, err: $0.err) },
            timeLabel: timeLabel,
            attachedTo: NSApp.keyWindow
        )
    }

    private func regionCentre(of region: Region) -> Region.Point {
        switch region.shape {
        case .circle(let c, _), .box(let c, _, _, _),
             .ellipse(let c, _, _, _), .annulus(let c, _, _): return c
        case .point(let p): return p
        case .polygon(let pts): return pts.first ?? .init(x: 0, y: 0)
        }
    }

    private func reprojectRegion(_ source: Region, toImagePixel p: (Double, Double)) -> Region {
        // Build a new image-frame region with the same shape parameters but a re-cast
        // centre. Radii in arcsec get converted to pixels using the source WCS local
        // scale (already handled when measuring); for simplicity here, if the source
        // was image-frame we just translate; if WCS-frame, we recast as image with the
        // converted centre and a fallback pixel-radius.
        let cx = p.0 + 1, cy = p.1 + 1   // FITS 1-based
        switch source.shape {
        case .circle(_, let r):
            return Region(shape: .circle(center: .init(x: cx, y: cy), radius: r),
                             frame: source.frame == .image ? .image : .image,
                             attributes: source.attributes)
        case .box(_, let w, let h, let a):
            return Region(shape: .box(center: .init(x: cx, y: cy), width: w, height: h, angle: a),
                             frame: .image, attributes: source.attributes)
        case .ellipse(_, let rx, let ry, let a):
            return Region(shape: .ellipse(center: .init(x: cx, y: cy), rx: rx, ry: ry, angle: a),
                             frame: .image, attributes: source.attributes)
        case .annulus(_, let i, let o):
            return Region(shape: .annulus(center: .init(x: cx, y: cy), innerRadius: i, outerRadius: o),
                             frame: .image, attributes: source.attributes)
        default:
            return source
        }
    }

    fileprivate func exportCubeAsMP4() {
        guard let hdu = document.file.hdus[safe: selectedHDU], hdu.naxis == 3 else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + ".mp4"
        guard let parent = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: parent) { resp in
            guard resp == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try MPEGExport.writeCube(
                        hdu: hdu,
                        to: url,
                        stretch: stretch,
                        vmin: Double(viewport.vmin),
                        vmax: Double(viewport.vmax),
                        colorMap: colorMap,
                        fps: 8
                    )
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    DispatchQueue.main.async {
                        let a = NSAlert(error: error)
                        a.runModal()
                    }
                }
            }
        }
    }

    fileprivate func detectSourcesAndAddRegions() {
        guard let image = currentImage() else { return }
        let detections = SourceExtractor.detect(image: image,
                                                threshold: nil,
                                                minSeparation: 3,
                                                backgroundBoxSize: 21,
                                                nSigma: 5)
        var newRegions: [Region] = []
        var fwhms: [Double] = []
        for d in detections {
            let near = (Int(d.x.rounded()), Int(d.y.rounded()))
            if let fit = GaussianFit.fit(image: image, near: near, boxRadius: 7), fit.sigmaX > 0.5 {
                let radius = max(2.0 * fit.sigmaX, 2.5)
                let label = String(format: "FWHM %.2f", fit.fwhm)
                fwhms.append(fit.fwhm)
                newRegions.append(Region(
                    shape: .circle(center: .init(x: fit.x + 1, y: fit.y + 1),
                                   radius: .init(value: radius, unit: .pixel)),
                    frame: .image,
                    attributes: ["color": "yellow", "text": label, "tag": "sources"]
                ))
            } else {
                newRegions.append(Region(
                    shape: .circle(center: .init(x: d.x + 1, y: d.y + 1),
                                   radius: .init(value: 4, unit: .pixel)),
                    frame: .image,
                    attributes: ["color": "yellow", "tag": "sources"]
                ))
            }
        }
        regions.append(contentsOf: newRegions)
        if !fwhms.isEmpty {
            let sorted = fwhms.sorted()
            let median = sorted[sorted.count / 2]
            let mean = fwhms.reduce(0, +) / Double(fwhms.count)
            let mn = sorted.first!, mx = sorted.last!
            let alert = NSAlert()
            alert.messageText = "Detected \(newRegions.count) sources (\(fwhms.count) Gaussian-fitted)"
            alert.informativeText = String(
                format: "FWHM (px) — median %.2f, mean %.2f, min %.2f, max %.2f",
                median, mean, mn, mx
            )
            alert.alertStyle = .informational
            alert.runModal()
        }
        NSLog("Detected \(newRegions.count) sources")
    }

    fileprivate func cropToSelectedRegion() {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx),
              let image = currentImage() else { NSSound.beep(); return }
        let region = regions[idx]
        let wcs = document.file.hdus[safe: selectedHDU].flatMap { WCS(header: $0.header) }
        guard let bbox = boundingBox(of: region, wcs: wcs, in: image) else { NSSound.beep(); return }
        let w = bbox.maxX - bbox.minX + 1
        let h = bbox.maxY - bbox.minY + 1
        guard w > 0, h > 0 else { return }
        var out = [Float](repeating: 0, count: w * h)
        for dy in 0..<h {
            for dx in 0..<w {
                out[dy * w + dx] = Float(image.physicalValue(x: bbox.minX + dx, y: bbox.minY + dy))
            }
        }
        let cropped = FITSImage.fromFloat32(pixels: out, width: w, height: h)
        displayOverride = DisplayOverride(image: cropped, wcs: nil,
                                          label: "Crop \(bbox.minX),\(bbox.minY) → \(bbox.maxX),\(bbox.maxY)")
        resetLevelsTrigger &+= 1
    }

    private func boundingBox(of region: Region, wcs: WCS?, in image: FITSImage) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard let candidate = containsPredicate(for: region, wcs: wcs) else { return nil }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<image.height {
            for x in 0..<image.width where candidate(x, y) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard minX <= maxX else { return nil }
        return (minX, minY, maxX, maxY)
    }

    private func containsPredicate(for region: Region, wcs: WCS?) -> ((Int, Int) -> Bool)? {
        switch region.shape {
        case .circle(let c, let r):
            guard let cp = imageCenter(of: c, frame: region.frame, wcs: wcs),
                  let rPix = pixelLength(r, frame: region.frame, wcs: wcs) else { return nil }
            return { x, y in
                let dx = Double(x) - cp.x, dy = Double(y) - cp.y
                return dx * dx + dy * dy <= rPix * rPix
            }
        case .box(let c, let w_, let h_, let a):
            guard let cp = imageCenter(of: c, frame: region.frame, wcs: wcs),
                  let wPix = pixelLength(w_, frame: region.frame, wcs: wcs),
                  let hPix = pixelLength(h_, frame: region.frame, wcs: wcs) else { return nil }
            let theta = a * .pi / 180
            let cosT = cos(theta), sinT = sin(theta)
            let halfW = wPix / 2, halfH = hPix / 2
            return { x, y in
                let dx = Double(x) - cp.x, dy = Double(y) - cp.y
                let lx =  dx * cosT + dy * sinT
                let ly = -dx * sinT + dy * cosT
                return abs(lx) <= halfW && abs(ly) <= halfH
            }
        case .ellipse(let c, let rx, let ry, let a):
            guard let cp = imageCenter(of: c, frame: region.frame, wcs: wcs),
                  let rxPix = pixelLength(rx, frame: region.frame, wcs: wcs),
                  let ryPix = pixelLength(ry, frame: region.frame, wcs: wcs),
                  rxPix > 0, ryPix > 0 else { return nil }
            let theta = a * .pi / 180
            let cosT = cos(theta), sinT = sin(theta)
            return { x, y in
                let dx = Double(x) - cp.x, dy = Double(y) - cp.y
                let lx =  dx * cosT + dy * sinT
                let ly = -dx * sinT + dy * cosT
                let nx = lx / rxPix, ny = ly / ryPix
                return nx * nx + ny * ny <= 1
            }
        case .annulus(let c, let rIn, let rOut):
            guard let cp = imageCenter(of: c, frame: region.frame, wcs: wcs),
                  let inPix = pixelLength(rIn, frame: region.frame, wcs: wcs),
                  let outPix = pixelLength(rOut, frame: region.frame, wcs: wcs) else { return nil }
            return { x, y in
                let dx = Double(x) - cp.x, dy = Double(y) - cp.y
                let d2 = dx * dx + dy * dy
                return d2 >= inPix * inPix && d2 <= outPix * outPix
            }
        case .polygon(let pts):
            guard region.frame == .image else { return nil }
            return { x, y in
                // Even-odd ray cast in image (0-based) frame.
                var inside = false
                var j = pts.count - 1
                for i in 0..<pts.count {
                    let xi = pts[i].x - 1, yi = pts[i].y - 1
                    let xj = pts[j].x - 1, yj = pts[j].y - 1
                    let pt = (Double(x), Double(y))
                    let intersects = ((yi > pt.1) != (yj > pt.1)) &&
                        (pt.0 < (xj - xi) * (pt.1 - yi) / (yj - yi + 1e-30) + xi)
                    if intersects { inside.toggle() }
                    j = i
                }
                return inside
            }
        case .point:
            return nil
        }
    }

    fileprivate func collapseCube(_ mode: FITSImage.CollapseMode) {
        guard let hdu = document.file.hdus[safe: selectedHDU], hdu.naxis == 3,
              let collapsed = try? FITSImage.collapsed(hdu: hdu, mode: mode) else { return }
        displayOverride = DisplayOverride(image: collapsed, wcs: WCS(header: hdu.header), label: "\(mode.label) over plane axis")
        resetLevelsTrigger &+= 1
    }

    fileprivate func openContourLevelsPanel() {
        let values = currentImage()?.physicalValues() ?? []
        let r = PixelStatistics.minMax(values)
        if !contourSpec.minValue.isFinite, let r { contourSpec.minValue = r.min }
        if !contourSpec.maxValue.isFinite, let r { contourSpec.maxValue = r.max }
        ContourLevelsWindowController.show(
            initial: contourSpec,
            dataMin: r?.min ?? .nan,
            dataMax: r?.max ?? .nan,
            onChange: { newSpec in
                contourSpec = newSpec
                recomputeContours()
            },
            attachedTo: NSApp.keyWindow
        )
    }

    private func recomputeContours() {
        guard contourSpec.enabled, let image = currentImage() else {
            contourSegments = []
            return
        }
        let levels = contourSpec.levels()
        contourSegments = Contours.segments(
            values: image.physicalValues(),
            width: image.width,
            height: image.height,
            levels: levels
        )
    }

    fileprivate func openScaleParametersPanel() {
        let parent = NSApp.keyWindow
        ScaleParametersWindowController.show(
            viewport: viewport,
            toolbarState: toolbarState,
            physicalValuesProvider: { currentImage()?.physicalValues() ?? [] },
            onApplyPreset: { preset in applyScalePreset(preset) },
            attachedTo: parent
        )
    }

    fileprivate func applyScalePreset(_ preset: ScalePreset) {
        guard let image = currentImage() else { return }
        let values = image.physicalValues()
        switch preset {
        case .zscale:
            if let r = PixelStatistics.zscale(values) {
                viewport.vmin = Float(r.z1)
                viewport.vmax = Float(r.z2)
            }
        case .minMax:
            if let r = PixelStatistics.minMax(values) {
                viewport.vmin = Float(r.min)
                viewport.vmax = Float(r.max)
            }
        case .percentile(let lo, let hi):
            if let r = PixelStatistics.percentiles(values, lower: lo, upper: hi) {
                viewport.vmin = Float(r.vmin)
                viewport.vmax = Float(r.vmax)
            }
        }
    }

    fileprivate func otherImageHDUIndices() -> [Int] {
        document.file.hdus.indices.filter { idx in
            idx != selectedHDU && document.file.hdus[idx].isImage && document.file.hdus[idx].naxis == 2
        }
    }

    fileprivate func hduLabel(_ idx: Int) -> String {
        guard let hdu = document.file.hdus[safe: idx] else { return "HDU \(idx)" }
        if let name = hdu.name { return "HDU \(idx) — \(name)" }
        return "HDU \(idx)"
    }

    fileprivate func canReproject(onto referenceIdx: Int) -> Bool {
        guard let active = document.file.hdus[safe: selectedHDU],
              let reference = document.file.hdus[safe: referenceIdx] else { return false }
        return WCS(header: active.header) != nil && WCS(header: reference.header) != nil
    }

    fileprivate func canDifference(against referenceIdx: Int) -> Bool {
        guard let active = document.file.hdus[safe: selectedHDU],
              let reference = document.file.hdus[safe: referenceIdx] else { return false }
        return active.axes == reference.axes
    }

    fileprivate func reproject(onto referenceIdx: Int) {
        guard let activeHdu = document.file.hdus[safe: selectedHDU],
              let refHdu = document.file.hdus[safe: referenceIdx],
              let activeImage = try? FITSImage(hdu: activeHdu),
              let sourceWCS = WCS(header: activeHdu.header),
              let targetWCS = WCS(header: refHdu.header),
              let refImage = try? FITSImage(hdu: refHdu) else { return }
        let reprojected = WCSReproject.reproject(
            source: activeImage,
            sourceWCS: sourceWCS,
            targetWCS: targetWCS,
            targetWidth: refImage.width,
            targetHeight: refImage.height
        )
        displayOverride = DisplayOverride(
            image: reprojected,
            wcs: targetWCS,
            label: "Reprojected onto HDU \(referenceIdx)"
        )
    }

    fileprivate func computeDifference(against referenceIdx: Int) {
        guard let activeHdu = document.file.hdus[safe: selectedHDU],
              let refHdu = document.file.hdus[safe: referenceIdx],
              let activeImage = try? FITSImage(hdu: activeHdu),
              let refImage = try? FITSImage(hdu: refHdu) else { return }
        do {
            let diff = try ImageArithmetic.difference(activeImage, minus: refImage)
            displayOverride = DisplayOverride(
                image: diff,
                wcs: WCS(header: activeHdu.header),
                label: "Difference vs HDU \(referenceIdx)"
            )
        } catch {
            NSLog("difference failed: \(error)")
        }
    }

    fileprivate func toggleBlink() {
        if let bs = blinkState {
            selectedHDU = bs.primary
            blinkState = nil
        } else {
            let count = document.file.hdus.count
            guard count >= 2 else { return }
            let partner = (selectedHDU + 1) % count
            blinkState = BlinkState(
                primary: selectedHDU,
                partner: partner,
                intervalSeconds: Self.blinkIntervalDefault,
                startedAt: Date()
            )
        }
    }

    fileprivate func fetchCatalog() async {
        guard let hdu = document.file.hdus[safe: selectedHDU],
              let image = try? FITSImage(hdu: hdu),
              let wcs = WCS(header: hdu.header),
              let cs = CatalogQuery.coneSearch(
                  wcs: wcs, imageWidth: image.width, imageHeight: image.height
              ) else { return }
        await MainActor.run { isFetchingCatalog = true }
        defer { Task { @MainActor in isFetchingCatalog = false } }
        do {
            let sources = try await AppCatalog.client.fetchGaia(
                centerRA: cs.centerRA,
                centerDec: cs.centerDec,
                radiusDeg: cs.radiusDeg,
                limit: 1000
            )
            let new = sources.map { s -> Region in
                // Brighter sources get a slightly larger marker (4–10 px).
                let mag = s.gMag ?? 20
                let radius = max(2, min(8, 16 - mag / 2))
                var attrs: [String: String] = ["color": "cyan", "tag": "Gaia"]
                if let mag = s.gMag {
                    attrs["text"] = String(format: "G=%.1f", mag)
                }
                return Region(
                    shape: .circle(center: .init(x: s.ra, y: s.dec),
                                   radius: .init(value: radius, unit: .pixel)),
                    frame: .fk5,
                    attributes: attrs
                )
            }
            await MainActor.run { regions.append(contentsOf: new) }
        } catch {
            NSLog("Catalog fetch failed: \(error.localizedDescription)")
        }
    }

    fileprivate func exportImage() {
        guard let hdu = document.file.hdus[safe: selectedHDU],
              let image = try? FITSImage(hdu: hdu) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .tiff]
        panel.nameFieldStringValue = "image.png"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let format: ExportFormat = url.pathExtension.lowercased() == "tiff" ? .tiff : .png
            do {
                try ImageExport.writeImage(image, stretch: stretch, format: format, to: url)
            } catch {
                NSLog("export failed: \(error)")
            }
        }
    }
}
