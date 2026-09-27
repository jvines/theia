import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FITSCore
import FITSRender
import TheiaKit

struct DocumentView: View {
    let document: DocumentModel
    @ObservedObject var toolbarState: ToolbarState
    let toolbarController: FITSToolbarController
    let pixelTableBridge: PixelTableCursorBridge

    @State private var session: DocumentSession
    @State private var autosaveWatcher: SessionAutosaveWatcher
    @State private var staleSession: SessionState?
    @State private var persistenceWarning: String?
    private let viewport: ImageViewState
    private let interaction: InteractionController

    private var stretch: ImageStretch {
        get { session.view.stretch }
        nonmutating set { session.perform(.setStretch(newValue), origin: .user) }
    }
    private var colorMap: ColorMap {
        get { session.view.colorMap }
        nonmutating set { session.perform(.setColormap(newValue), origin: .user) }
    }
    private var regions: [Region] {
        get { session.regions }
        nonmutating set { session.regions = newValue }
    }
    private var selectedRegionIndex: Int? {
        get { session.selectedRegionIndex }
        nonmutating set { session.selectedRegionIndex = newValue }
    }
    private var previewRegion: Region? {
        get { session.previewRegion }
        nonmutating set { session.previewRegion = newValue }
    }
    private var showWCSGrid: Bool {
        get { session.showGrid }
        nonmutating set { session.perform(.setGridVisible(newValue), origin: .user) }
    }
    private var showCompass: Bool {
        get { session.showCompass }
        nonmutating set { session.perform(.setCompassVisible(newValue), origin: .user) }
    }
    private var showColorBar: Bool {
        get { session.showColorBar }
        nonmutating set { session.perform(.setColorBarVisible(newValue), origin: .user) }
    }
    private var contourSpec: ContourSpec {
        get { session.contourSpec }
        nonmutating set { session.perform(.setContourSpec(newValue), origin: .user) }
    }
    private var contourSegments: [Contours.LeveledSegments] { session.contourSegments }
    private var drawMode: DrawMode {
        get { session.mode }
        nonmutating set { session.perform(.setDrawMode(newValue), origin: .user) }
    }
    private var profileGeometry: ProfileGeometry? {
        get { session.profileMarker }
        nonmutating set { session.profileMarker = newValue }
    }
    private var cursor: CursorInfo? {
        get { session.cursor }
        nonmutating set { session.cursor = newValue }
    }
    private var showInspector: Bool {
        get { session.inspectorVisible }
        nonmutating set { session.inspectorVisible = newValue }
    }
    private var isFetchingCatalog: Bool {
        get { session.catalogFetchInProgress }
    }
    private var planePlaying: Bool {
        get { session.playing }
        nonmutating set { session.perform(.setPlaying(newValue), origin: .user) }
    }
    private var blinkState: BlinkState? { session.blink }
    private var playingBinding: Binding<Bool> {
        Binding(get: { session.playing }, set: { session.perform(.setPlaying($0), origin: .user) })
    }
    private var fpsBinding: Binding<Double> {
        Binding(get: { session.fps }, set: { session.perform(.setFPS($0), origin: .user) })
    }
    private var inspectorTabBinding: Binding<InspectorTab> {
        Binding(get: { session.inspectorTab }, set: { session.inspectorTab = $0 })
    }
    private var regionsBinding: Binding<[Region]> {
        Binding(get: { session.regions }, set: { session.regions = $0 })
    }

    private var selectedHDU: Int {
        get { session.hdu }
        nonmutating set { session.perform(.selectHDU(newValue), origin: .user) }
    }
    private var selectedPlane: Int {
        get { session.plane }
        nonmutating set { session.perform(.selectPlane(newValue), origin: .user) }
    }
    private var activeWCSVariant: String {
        get { session.wcsVariant }
        nonmutating set { session.perform(.selectWCSVariant(newValue), origin: .user) }
    }
    private var imageRevision: Int { session.imageRevision }
    private var hduBinding: Binding<Int> {
        Binding(get: { selectedHDU }, set: { selectedHDU = $0 })
    }
    private var planeBinding: Binding<Int> {
        Binding(get: { selectedPlane }, set: { selectedPlane = $0 })
    }

    init(document: DocumentModel,
         toolbarState: ToolbarState,
         toolbarController: FITSToolbarController,
         pixelTableBridge: PixelTableCursorBridge) {
        self.document = document
        self.toolbarState = toolbarState
        self.toolbarController = toolbarController
        self.pixelTableBridge = pixelTableBridge
        self.viewport = document.session.view
        self.interaction = InteractionController(view: document.session.view, mode: .full,
                                                 session: document.session)
        self._session = State(initialValue: document.session)
        self._autosaveWatcher = State(initialValue: SessionAutosaveWatcher(session: document.session) { state in
            guard let identity = document.fileIdentity else { throw SessionStore.StoreError.invalidFITSHeader }
            try document.sessionStore.save(state, for: document.url, identity: identity)
        })
        self._staleSession = State(initialValue: document.staleState)
        self._persistenceWarning = State(initialValue: document.persistenceErrorMessage)
        self.interaction.regionColorProvider = { UserPreferences.shared.regionColor }
    }

    var body: some View {
        // Manual three-column layout (NavigationSplitView would hijack the NSToolbar).
        HStack(spacing: 0) {
            HDUSidebar(file: document.file, selection: hduBinding)
                .frame(width: 200)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                if let hdu = document.file.hdus[safe: selectedHDU] {
                    makeImageView(hdu: hdu)
                    StatusBar(
                        hdu: hdu,
                        planeCount: session.facts[selectedHDU].planeCount,
                        plane: planeBinding,
                        planePlaying: playingBinding,
                        planeFPS: fpsBinding,
                        cursor: cursor,
                        wcs: session.displayedWCS,
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
                    tab: inspectorTabBinding,
                    regions: regionsBinding,
                    session: session,
                    imageProvider: { currentImage() },
                    onEffect: { applyEffect($0) }
                )
                    .frame(width: 340)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow, phases: .down) { handleKey(.leftArrow, modifiers: $0.modifiers) }
            .onKeyPress(.rightArrow, phases: .down) { handleKey(.rightArrow, modifiers: $0.modifiers) }
            .onKeyPress(.upArrow, phases: .down) { handleKey(.upArrow, modifiers: $0.modifiers) }
            .onKeyPress(.downArrow, phases: .down) { handleKey(.downArrow, modifiers: $0.modifiers) }
            .onKeyPress(.space, phases: .down) { handleKey(.space, modifiers: $0.modifiers) }
            .onKeyPress(.delete, phases: .down) { handleKey(.delete, modifiers: $0.modifiers) }
            .onKeyPress(.deleteForward, phases: .down) { handleKey(.forwardDelete, modifiers: $0.modifiers) }
            .onKeyPress(.escape, phases: .down) { handleKey(.escape, modifiers: $0.modifiers) }
            .onKeyPress("d", phases: .down) { handleKey(.character("d"), modifiers: $0.modifiers) }
            .onKeyPress("z", phases: .down) { handleKey(.character("z"), modifiers: $0.modifiers) }
            .onKeyPress("=", phases: .down) { handleKey(.character("="), modifiers: $0.modifiers) }
            .onKeyPress("+", phases: .down) { handleKey(.character("+"), modifiers: $0.modifiers) }
            .onKeyPress("-", phases: .down) { handleKey(.character("-"), modifiers: $0.modifiers) }
            .onAppear {
                syncToolbarState()
                // Keep new edits even while an older stale session awaits a
                // decision; SessionStore preserves that archive separately.
                autosaveWatcher.start()
            }
            .onDisappear { autosaveWatcher.close() }
            .background(DocumentKeyEventMonitor(interaction: interaction))
            .overlay(alignment: .top) { persistenceNotices }
            // Collapse 11 toolbar-trigger .onChange entries into a single
            // snapshot-driven .onChange. Cuts the SwiftUI type-checker load
            // on this body and centralises the dependency list.
            .onChange(of: toolbarSyncSnapshot) { _, _ in syncToolbarState() }
            .onChange(of: imageRevision) { _, revision in
                pixelTableBridge.imageRevision = revision
            }
            .onChange(of: session.sourceDetectionNoticeID) { _, _ in
                guard let title = session.sourceDetectionNoticeTitle,
                      let message = session.sourceDetectionNoticeMessage else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.alertStyle = .informational
                alert.runModal()
            }
            .onChange(of: session.catalogNoticeID) { _, _ in
                guard let message = session.catalogErrorMessage else { return }
                let alert = NSAlert()
                alert.messageText = "Catalog fetch failed"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.runModal()
            }
            .onChange(of: session.imageOperationNoticeID) { _, _ in
                guard let message = session.imageOperationErrorMessage else { return }
                applyEffect(.alert(title: "Image operation failed", message: message,
                                   style: .warning))
            }
    }

    @ViewBuilder private var persistenceNotices: some View {
        VStack(spacing: 8) {
            if staleSession != nil {
                HStack(spacing: 12) {
                    Text("This file changed since its session was saved.")
                    Button("Restore anyway") { restoreStaleSession() }
                    Button("Dismiss") { dismissStaleSession() }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let failure = autosaveWatcher.failureMessage {
                HStack(spacing: 12) {
                    Text("Session could not be saved: \(failure)")
                    Button("Dismiss") { autosaveWatcher.dismissFailure() }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let warning = persistenceWarning {
                HStack(spacing: 12) {
                    Text("Session could not be loaded: \(warning)")
                    Button("Dismiss") { persistenceWarning = nil }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 8)
    }

    private func restoreStaleSession() {
        guard let staleSession else { return }
        autosaveWatcher.start()
        session.restoreInitialState(staleSession)
        self.staleSession = nil
        autosaveWatcher.schedule()
    }

    private func dismissStaleSession() {
        do {
            try document.sessionStore.discardStale(for: document.url)
            staleSession = nil
            autosaveWatcher.start()
            autosaveWatcher.schedule()
        } catch {
            persistenceWarning = error.localizedDescription
        }
    }

    private func handleKey(_ key: KeyEvent.Key, modifiers: EventModifiers) -> KeyPress.Result {
        var input: PointerEvent.Modifiers = []
        if modifiers.contains(.shift) { input.insert(.shift) }
        if modifiers.contains(.command) { input.insert(.primary) }
        if modifiers.contains(.option) { input.insert(.option) }
        if modifiers.contains(.control) { input.insert(.control) }
        return interaction.key(KeyEvent(key: key, modifiers: input)) ? .handled : .ignored
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
            imageRevision: imageRevision,
            hasDisplayOverride: session.derived != nil,
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
    let imageRevision: Int
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
                    Text(DocumentText.sidebarDetails(for: hdu))
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
    let planeCount: Int
    @Binding var plane: Int
    @Binding var planePlaying: Bool
    @Binding var planeFPS: Double
    let cursor: CursorInfo?
    let wcs: WCS?
    let viewport: ImageViewState

    /// Persisted readout frame (shared across windows/sessions).
    @AppStorage(PreferenceKeys.ReadoutFrame.name) private var coordFrameRaw = CelestialFrame.icrs.rawValue
    private var coordFrame: CelestialFrame { CelestialFrame(rawValue: coordFrameRaw) ?? .icrs }

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
        if planeCount > 1 {
            CubePlaneControl(
                plane: $plane,
                planeCount: planeCount,
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
            Text(DocumentText.statusDetails(for: hdu))
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
                Text(DocumentText.pixelCoordinates(imageX: c.imageX, imageY: c.imageY))
                    .font(.system(.body, design: .monospaced))
                Text("=").foregroundStyle(.secondary)
                Text(DocumentText.pixelValue(c.value))
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
            Text(DocumentText.level(viewport.vmin))
                .font(.system(.body, design: .monospaced))
            Text("max").foregroundStyle(.tertiary)
            Text(DocumentText.level(viewport.vmax))
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

}

struct FITSImageView: View {
    let hdu: FITSHDU
    let displayed: FITSImage?
    let displayedWCS: WCS?
    let imageRevision: Int
    let stretch: ImageStretch
    let colorMap: ColorMap
    let viewport: ImageViewState
    let interaction: InteractionController
    let showWCSGrid: Bool
    let showCompass: Bool
    let showColorBar: Bool
    let contourSegments: [Contours.LeveledSegments]
    let drawMode: DrawMode
    let regions: [Region]
    let selectedRegionIndex: Int?
    let previewRegion: Region?
    let onCursorChange: (CursorInfo?) -> Void
    let onLineProfile: (SIMD2<Double>, SIMD2<Double>) -> Void
    let onRadialProfile: (SIMD2<Double>, Double) -> Void
    let onGrowthCurve: (SIMD2<Double>, Double) -> Void
    let onMeasure: (SIMD2<Double>, SIMD2<Double>) -> Void
    let onCubeSpectrumAt: (SIMD2<Double>) -> Void
    let onRegionContextMenu: (Int, NSEvent) -> Void
    let remoteCrosshair: SIMD2<Double>?
    let profileGeometry: ProfileGeometry?

    var body: some View {
        if displayed == nil, hdu.isTable, let table = FITSTableLoader.load(hdu) {
            TableExtensionView(table: table)
        } else if let image = displayed {
            let wcs = displayedWCS
            ZStack {
                FITSMetalView(
                    image: image,
                    imageRevision: imageRevision,
                    viewport: viewport,
                    drawMode: drawMode,
                    interactionController: interaction,
                    onCursorChange: onCursorChange,
                    onLineProfile: onLineProfile,
                    onRadialProfile: onRadialProfile,
                    onGrowthCurve: onGrowthCurve,
                    onMeasure: onMeasure,
                    onCubeSpectrumAt: onCubeSpectrumAt,
                    onRegionContextMenu: onRegionContextMenu
                )
                if showWCSGrid, let wcs {
                    WCSGridOverlay(image: image, wcs: wcs, viewport: viewport)
                }
                if !regions.isEmpty || previewRegion != nil {
                    RegionOverlay(regions: regions, selectedIndex: selectedRegionIndex,
                                  previewRegion: previewRegion, wcs: wcs, viewport: viewport)
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
    @Binding var tab: InspectorTab
    @Binding var regions: [Region]
    let session: DocumentSession
    let imageProvider: () -> FITSImage?
    let onEffect: (Effect) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)
            switch tab {
            case .header: HeaderPanel(header: header, hduIndex: session.hdu,
                                      editor: session.headerEditor, imageProvider: imageProvider)
            case .regions: RegionListPanel(regions: $regions, session: session, onEffect: onEffect)
            case .photometry: PhotometryPanel(session: session)
            case .stats: ImageStatsPanel(session: session)
            }
        }
    }
}

struct RegionListPanel: View {
    @Binding var regions: [Region]
    let session: DocumentSession
    let onEffect: (Effect) -> Void
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    performAndApply(.loadRegions)
                } label: { Label("Load…", systemImage: "tray.and.arrow.down") }
                Button {
                    performAndApply(.saveRegions)
                } label: { Label("Save…", systemImage: "tray.and.arrow.up") }
                    .disabled(regions.isEmpty)
                Spacer()
                if !regions.isEmpty {
                    Button(role: .destructive) {
                        session.perform(.clearRegions, origin: .user)
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
        .onChange(of: session.regionReplacementRevision) { _, _ in expanded.removeAll() }
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
                            Text(RegionList.summary(for: region))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                session.perform(.deleteRegion(idx), origin: .user)
                                expanded.remove(idx)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        if expanded.contains(idx) {
                            RegionEditor(region: Binding(
                                get: { regions[idx] },
                                set: { session.perform(.updateRegion(idx, $0), origin: .user) }
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

    private func performAndApply(_ command: SessionCommand) {
        let outcome = session.perform(command, origin: .user)
        for effect in outcome.effects { onEffect(effect) }
    }
}

struct HeaderPanel: View {
    let header: FITSHeader
    let hduIndex: Int
    @Bindable var editor: HeaderEditor
    let imageProvider: () -> FITSImage?

    var rows: [HeaderRow] { editor.filteredRows(in: header) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter…", text: $editor.search).textFieldStyle(.roundedBorder)
                Toggle("Edit", isOn: $editor.editing).toggleStyle(.button).controlSize(.small)
                Button {
                    saveEditedFITS()
                } label: { Label("Save modified…", systemImage: "tray.and.arrow.up") }
                .controlSize(.small)
                .disabled(editor.editCount(for: hduIndex) == 0)
            }
            .padding(8)
            if editor.editing {
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
                            .foregroundStyle(editor.hasEdit(at: row.id, hdu: hduIndex) ? .primary : .secondary)
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
            let editCount = editor.editCount(for: hduIndex)
            if editCount > 0 {
                Text("\(editCount) edited card\(editCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    private func valueBinding(for row: HeaderRow) -> Binding<String> {
        Binding(
            get: { editor.valueText(for: row.card, at: row.id, hdu: hduIndex) },
            set: { editor.setValue($0, for: row.card, at: row.id, hdu: hduIndex) }
        )
    }

    private func commentBinding(for row: HeaderRow) -> Binding<String> {
        Binding(
            get: { editor.commentText(for: row.card, at: row.id, hdu: hduIndex) },
            set: { editor.setComment($0, for: row.card, at: row.id, hdu: hduIndex) }
        )
    }

    private func saveEditedFITS() {
        guard let image = imageProvider() else { NSSound.beep(); return }
        let extra = editor.serializedExtraCards(from: header, hdu: hduIndex)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fits") ?? .data]
        panel.nameFieldStringValue = "modified.fits"
        guard let win = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try FITSWriter.write(image, to: url, extraCards: extra)
                editor.clearEdits(for: hduIndex)
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
        toolbarState.hasWCS = session.displayedWCS != nil
        if selected != nil {
            toolbarState.wcsVariants = session.availableWCSVariants
            toolbarState.wcsVariantLabels = session.wcsVariantLabels
            toolbarState.activeWCSVariant = activeWCSVariant
        }
        toolbarState.hasMultipleHDUs = document.file.hdus.count >= 2
        toolbarState.onEffect           = { effect in applyEffect(effect) }
        toolbarState.onReproject        = { reproject(onto: $0) }
        toolbarState.onFetchCatalog     = {
            let outcome = session.perform(.fetchCatalog, origin: .user)
            if let failure = outcome.failure {
                applyEffect(.alert(title: "Catalog fetch failed", message: failure.message,
                                   style: .warning))
            }
        }
        toolbarState.onOpenScaleParameters = { performAndApply(.showPanel(.scaleParameters)) }
        toolbarState.onOpenPixelTable = { performAndApply(.showPanel(.pixelTable)) }
        toolbarState.onOpenContourLevels = { performAndApply(.showPanel(.contourLevels)) }
        toolbarState.onCollapseCube = { mode in collapseCube(mode) }
        toolbarState.onDetectSources = { detectSourcesAndAddRegions() }
        toolbarState.onCropToSelection = { cropToSelectedRegion() }
        toolbarState.onSubtractBackground = { subtractBackground() }
        toolbarState.onBinImage = { n in binImage(by: n) }
        toolbarState.onStackOpenDocuments = { mode in stackOpenDocuments(mode: mode) }
        toolbarState.onLightCurve = { generateLightCurve() }
        toolbarState.onApplyFilter = { spec in applyFilter(spec) }
        toolbarState.onApplyUnary = { op in applyUnary(op) }
        toolbarState.onApplyBinary = { op, idx in applyBinary(op, other: idx) }
    }

    @ViewBuilder
    fileprivate func makeImageView(hdu: FITSHDU) -> some View {
        FITSImageView(
            hdu: hdu,
            displayed: session.displayed,
            displayedWCS: session.displayedWCS,
            imageRevision: imageRevision,
            stretch: stretch,
            colorMap: colorMap,
            viewport: viewport,
            interaction: interaction,
            showWCSGrid: showWCSGrid,
            showCompass: showCompass,
            showColorBar: showColorBar,
            contourSegments: contourSpec.enabled ? contourSegments : [],
            drawMode: drawMode,
            regions: regions,
            selectedRegionIndex: selectedRegionIndex,
            previewRegion: previewRegion,
            onCursorChange: handleCursor,
            onLineProfile: { from, to in handleLineProfile(from: from, to: to) },
            onRadialProfile: { center, r in handleRadialProfile(center: center, radius: r) },
            onGrowthCurve: { center, r in handleGrowthCurve(center: center, radius: r) },
            onMeasure: { from, to in handleMeasure(from: from, to: to) },
            onCubeSpectrumAt: { p in handleCubeSpectrum(at: p) },
            onRegionContextMenu: { idx, event in showRegionContextMenu(index: idx, event: event) },
            remoteCrosshair: session.remoteCrosshair,
            profileGeometry: profileGeometry
        )
    }

    private func handleLineProfile(from: SIMD2<Double>, to: SIMD2<Double>) {
        guard let hdu = document.file.hdus[safe: selectedHDU] else { return }
        let n = LineProfileModel.sampleCount(from: from, to: to)
        let marker = ProfileGeometry.line(from: from, to: to)
        if hdu.naxis == 3 {
            guard let pv = try? Profiles.pvDiagram(hdu: hdu, from: (from.x, from.y), to: (to.x, to.y), samples: n) else { return }
            PVDiagramWindowController.show(image: pv, imageName: document.url.lastPathComponent,
                                           attachedTo: NSApp.keyWindow,
                                           onClose: ProfileWindowMarker.onClose(marker, in: session))
            profileGeometry = marker
            return
        }
        guard let image = currentImage() else { return }
        let model = LineProfileModel(image: image, from: from, to: to)
        LineProfileWindowController.show(model: model, imageName: document.url.lastPathComponent,
                                         attachedTo: NSApp.keyWindow,
                                         onClose: ProfileWindowMarker.onClose(marker, in: session))
        profileGeometry = marker
    }

    private func handleRadialProfile(center: SIMD2<Double>, radius: Double) {
        guard let image = currentImage() else { return }
        let maxR = radius > 0 ? radius : Double(min(image.width, image.height)) / 2
        RadialProfileWindowController.show(
            image: image,
            center: center,
            initialRadius: maxR,
            imageName: document.url.lastPathComponent,
            attachedTo: NSApp.keyWindow,
            onRadiusChange: { [weak session] newR in
                _ = session?.perform(.setProfileRadius(newR), origin: .user)
            },
            onClose: ProfileWindowMarker.onRadialClose(center: center, in: session)
        )
        profileGeometry = .radial(center: center, maxRadius: maxR)
    }

    private func handleMeasure(from: SIMD2<Double>, to: SIMD2<Double>) {
        let measurement = Measurements.between(from: from, to: to, wcs: session.displayedWCS)
        let alert = NSAlert()
        alert.messageText = "Measurement"
        alert.informativeText = measurement.lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func handleGrowthCurve(center: SIMD2<Double>, radius: Double) {
        guard let image = currentImage() else { return }
        let maxR = radius > 0 ? radius : min(Double(image.width), Double(image.height)) / 2
        GrowthCurveWindowController.show(
            image: image,
            center: center,
            initialRadius: maxR,
            imageName: document.url.lastPathComponent,
            attachedTo: NSApp.keyWindow,
            onRadiusChange: { [weak session] newR in
                _ = session?.perform(.setProfileRadius(newR), origin: .user)
            },
            onClose: ProfileWindowMarker.onGrowthClose(center: center, in: session)
        )
        profileGeometry = .growth(center: center, maxRadius: maxR)
    }

    private func handleCubeSpectrum(at p: SIMD2<Double>) {
        guard let hdu = document.file.hdus[safe: selectedHDU], hdu.naxis == 3 else { return }
        let marker = ProfileGeometry.point(p)
        let wcs = WCS(header: hdu.header, variant: activeWCSVariant)
        let axis = SpectralAxis(header: hdu.header)
        let xs = axis?.values(planeCount: hdu.planeCount)
        let xLabel = axis?.axisLabel ?? "plane"
        let hit = RegionHitTest.hit(in: regions, atImagePoint: p, toleranceImagePixels: 4, wcs: wcs)
        if let h = hit, regions.indices.contains(h.regionIndex),
           let values = try? Profiles.cubeSpectrum(hdu: hdu, region: regions[h.regionIndex], wcs: wcs, combine: .sum) {
            let model = CubeSpectrumModel(values: values, currentPlane: selectedPlane,
                                          label: "region #\(h.regionIndex) (sum)",
                                          xValues: xs, xLabel: xLabel)
            CubeSpectrumWindowController.show(
                model: model, attachedTo: NSApp.keyWindow,
                onClose: ProfileWindowMarker.onClose(marker, in: session))
            profileGeometry = marker
            return
        }
        let pixel = (Int(p.x.rounded()), Int(p.y.rounded()))
        guard let values = try? Profiles.cubeSpectrum(hdu: hdu, atPixel: pixel) else { return }
        let model = CubeSpectrumModel(values: values, currentPlane: selectedPlane,
                                      label: "pixel (\(pixel.0), \(pixel.1))",
                                      xValues: xs, xLabel: xLabel)
        CubeSpectrumWindowController.show(
            model: model, attachedTo: NSApp.keyWindow,
            onClose: ProfileWindowMarker.onClose(marker, in: session))
        profileGeometry = marker
    }

    private func handleCursor(_ info: CursorInfo?) {
        cursor = info
        pixelTableBridge.cursor = info
    }

    private func updateRegion(idx: Int, region: Region) {
        session.perform(.updateRegion(idx, region), origin: .user)
    }

    fileprivate func showRegionContextMenu(index: Int, event: NSEvent) {
        guard regions.indices.contains(index), let view = NSApp.keyWindow?.contentView else { return }
        selectedRegionIndex = index
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Duplicate") {
            _ = duplicateSelectedRegion()
        })
        menu.addItem(makeMenuItem("Delete") {
            performAndApply(.deleteRegion(index))
        })
        menu.addItem(makeMenuItem("Bring to front") {
            performAndApply(.bringRegionToFront(index))
        })
        menu.addItem(.separator())
        // Copy as .reg text.
        menu.addItem(makeMenuItem("Copy as .reg text") {
            performAndApply(.copyRegion(index))
        })
        // Submenu: color
        let colorMenu = NSMenu()
        for c in RegionList.colors {
            colorMenu.addItem(makeMenuItem(c.capitalized) {
                guard regions.indices.contains(index) else { return }
                updateRegion(idx: index, region: RegionList.settingAttribute(.color, to: c, in: regions[index]))
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
        guard let idx = selectedRegionIndex else { return .ignored }
        return session.perform(.deleteRegion(idx), origin: .user).failure == nil
            ? .handled : .ignored
    }

    fileprivate func nudgeSelected(dx: Int, dy: Int, shift: Bool) -> KeyPress.Result {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx) else { return .ignored }
        let step = shift ? 10.0 : 1.0
        return session.perform(.nudgeRegion(idx, dx: Double(dx) * step,
                                            dy: Double(dy) * step), origin: .user).failure == nil
            ? .handled : .ignored
    }

    fileprivate func duplicateSelectedRegion() -> KeyPress.Result {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx) else { return .ignored }
        return session.perform(.duplicateRegion(idx, dx: 5, dy: 5), origin: .user).failure == nil
            ? .handled : .ignored
    }

    fileprivate func currentImage() -> FITSImage? {
        session.displayed
    }

    fileprivate func applyFilter(_ spec: FilterSpec) {
        performImageCommand(.filter(spec))
    }

    fileprivate func applyUnary(_ op: ImageArithmetic.UnaryOp) {
        performImageCommand(.unary(op))
    }

    fileprivate func applyBinary(_ op: ImageArithmetic.BinaryOp, other otherIdx: Int) {
        performImageCommand(.binary(op, otherIdx))
    }

    fileprivate func subtractBackground() {
        performImageCommand(.subtractBackground)
    }

    fileprivate func binImage(by n: Int) {
        performImageCommand(.bin(n))
    }

    private func extractCubeSlab(from: Int, to: Int) {
        performImageCommand(.applySlab(from: from, to: to))
    }

    fileprivate func stackOpenDocuments(mode: StackMode) {
        let allControllers = AppDelegate.shared?.allControllersForScripting() ?? []
        let otherImages: [FITSImage] = allControllers
            .filter { $0.documentModel.session !== session }
            .compactMap { $0.currentOverrideImage() }
        guard !otherImages.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Stack requires ≥ 2 open documents"
            alert.informativeText = "Open another FITS file in a second window first."
            alert.runModal()
            return
        }
        let outcome = session.stack(with: otherImages, mode: mode)
        if let failure = outcome.failure {
            applyEffect(.alert(title: "Stack failed", message: failure.message,
                               style: .warning))
        }
    }

    fileprivate func generateLightCurve() {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx) else {
            let a = NSAlert()
            a.messageText = "Pick a region first"
            a.informativeText = "Select an aperture region (a circle is typical) before generating a light curve. The region's sky position is reprojected into each open file via WCS."
            a.runModal(); return
        }
        guard let refWCS = session.displayedWCS else {
            let a = NSAlert()
            a.messageText = "Reference image has no WCS"
            a.informativeText = "Light curves need WCS to project the aperture onto each open document."
            a.runModal(); return
        }
        let controllers = AppDelegate.shared?.allControllersForScripting() ?? []
        let frames = controllers.compactMap { controller -> LightCurveFrame? in
            let session = controller.documentModel.session
            guard let hdu = controller.documentModel.file.hdus[safe: session.hdu],
                  let image = session.displayed,
                  let wcs = session.displayedWCS else { return nil }
            return LightCurveFrame(image: image, wcs: wcs, header: hdu.header)
        }
        guard let curve = LightCurveBuilder.build(region: regions[idx], referenceWCS: refWCS,
                                                  frames: frames) else {
            let a = NSAlert()
            a.messageText = "Need ≥ 2 open documents"
            a.informativeText = "Open more files of the same field, then run Light curve again."
            a.runModal(); return
        }
        LightCurveWindowController.show(model: curve, attachedTo: NSApp.keyWindow)
    }

    fileprivate func detectSourcesAndAddRegions() {
        _ = session.perform(.detectSources, origin: .user)
    }

    fileprivate func cropToSelectedRegion() {
        performImageCommand(.cropToSelection)
    }

    fileprivate func collapseCube(_ mode: FITSImage.CollapseMode) {
        performImageCommand(.collapseCube(mode))
    }

    fileprivate func openContourLevelsPanel() {
        let values = currentImage()?.physicalValues() ?? []
        let r = PixelStatistics.minMax(values)
        let model = ContourLevelsModel(initial: contourSpec,
                                       dataMin: r?.min ?? .nan,
                                       dataMax: r?.max ?? .nan)
        contourSpec = model.spec
        ContourLevelsWindowController.show(
            model: model,
            onChange: { [weak session] newSpec in
                _ = session?.perform(.setContourSpec(newSpec), origin: .user)
            },
            attachedTo: NSApp.keyWindow
        )
    }

    fileprivate func performAndApply(_ command: SessionCommand) {
        let outcome = session.perform(command, origin: .user)
        guard outcome.failure == nil else { return }
        for effect in outcome.effects { applyEffect(effect) }
    }

    fileprivate func performImageCommand(_ command: SessionCommand) {
        let outcome = session.perform(command, origin: .user)
        if let failure = outcome.failure {
            applyEffect(.alert(title: "Image operation failed", message: failure.message,
                               style: .warning))
            return
        }
        for effect in outcome.effects { applyEffect(effect) }
    }

    fileprivate func applyEffect(_ effect: Effect) {
        switch effect {
        case .ask(.savePath(let suggestedName, let types), let request):
            let panel = NSSavePanel()
            panel.allowedContentTypes = types.compactMap {
                UTType($0) ?? UTType(filenameExtension: $0)
            }
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
                let answer: Answer
                if response == .OK, let url = panel.url { answer = .path(url) }
                else { answer = .cancelled }
                let outcome = session.perform(.answer(request, answer), origin: .user)
                for next in outcome.effects { applyEffect(next) }
            }
            let usesSheet: Bool
            switch request {
            case .exportCube, .saveImage, .saveRegions: usesSheet = true
            default: usesSheet = false
            }
            if usesSheet, let parent = NSApp.keyWindow {
                panel.beginSheetModal(for: parent, completionHandler: handleResponse)
            } else {
                panel.begin(completionHandler: handleResponse)
            }
        case .ask(.openPath(let types, let multiple), let request):
            let panel = NSOpenPanel()
            panel.allowedContentTypes = types.compactMap {
                UTType($0) ?? UTType(filenameExtension: $0)
            }
            panel.allowsMultipleSelection = multiple
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
                let answer: Answer = response == .OK ? .paths(panel.urls) : .cancelled
                let outcome = session.perform(.answer(request, answer), origin: .user)
                for next in outcome.effects { applyEffect(next) }
            }
            if let parent = NSApp.keyWindow {
                panel.beginSheetModal(for: parent, completionHandler: handleResponse)
            } else {
                panel.begin(completionHandler: handleResponse)
            }
        case .ask(.numbers(let prompt, let fields), let request):
            let alert = NSAlert()
            alert.messageText = "Extract Cube Slab"
            alert.informativeText = prompt
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 8
            let defaults: [String]
            if case .slab(let slab) = request {
                defaults = ["0", "\(slab.planeCount - 1)"]
            } else {
                defaults = Array(repeating: "0", count: fields.count)
            }
            let inputs = fields.enumerated().map { index, label -> NSTextField in
                let input = NSTextField(string: defaults[index])
                input.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
                stack.addArrangedSubview(NSTextField(labelWithString: label))
                stack.addArrangedSubview(input)
                return input
            }
            stack.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Extract")
            alert.addButton(withTitle: "Cancel")
            let answer: Answer = alert.runModal() == .alertFirstButtonReturn
                ? .numbers(inputs.map { Double($0.stringValue) ?? .nan }) : .cancelled
            let outcome = session.perform(.answer(request, answer), origin: .user)
            for next in outcome.effects { applyEffect(next) }
        case .ask:
            break
        case .exportImage(let snapshot, let url):
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try snapshot.writeImage(to: url)
                } catch {
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
            }
        case .exportCube(let snapshot, let url):
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try MPEGExport.writeCube(
                        hdu: snapshot.hdu, to: url, stretch: snapshot.stretch,
                        vmin: Double(snapshot.vmin), vmax: Double(snapshot.vmax),
                        colorMap: snapshot.colorMap, parameter: snapshot.stretchParameter,
                        fps: snapshot.fps
                    )
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
            }
        case .saveImage(let snapshot, let url):
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try snapshot.writeFITS(to: url)
                } catch {
                    DispatchQueue.main.async {
                        applyEffect(.alert(title: "FITS image not saved",
                                           message: error.localizedDescription, style: .warning))
                    }
                }
            }
        case .extractSlab(let request, let from, let to):
            guard request.documentID == session.id,
                  request.hduIndex == session.hdu,
                  request.imageRevision == session.imageRevision else { return }
            extractCubeSlab(from: from, to: to)
        case .saveRegions(let snapshot, let url):
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try snapshot.write(to: url)
                } catch {
                    DispatchQueue.main.async {
                        applyEffect(.alert(title: "Regions not saved",
                                           message: error.localizedDescription, style: .warning))
                    }
                }
            }
        case .loadRegions(let request, let url):
            guard request.documentID == session.id else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let loaded = try RegionFile.parse(text)
                    DispatchQueue.main.async {
                        let outcome = session.perform(.completeRegionLoad(request, loaded), origin: .user)
                        if let failure = outcome.failure, failure != .supersededRegionLoad {
                            applyEffect(.alert(title: "Regions not loaded",
                                               message: failure.message, style: .warning))
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        applyEffect(.alert(title: "Regions not loaded",
                                           message: error.localizedDescription, style: .warning))
                    }
                }
            }
        case .showPanel(.scaleParameters): openScaleParametersPanel()
        case .showPanel(.pixelTable):
            PixelTableWindowController.show(
                provider: { currentImage() },
                cursorPublisher: pixelTableBridge,
                attachedTo: NSApp.keyWindow
            )
        case .showPanel(.contourLevels): openContourLevelsPanel()
        case .documentOpened, .noteRecent, .alert, .showAppWindow, .openURL,
             .copyToClipboard, .tileWindows, .quit:
            AppDelegate.shared?.applyEffect(effect)
        }
    }

    fileprivate func openScaleParametersPanel() {
        let parent = NSApp.keyWindow
        ScaleParametersWindowController.show(
            viewport: viewport,
            physicalValuesProvider: { currentImage()?.physicalValues() ?? [] },
            onApplyPreset: { preset in applyScalePreset(preset) },
            attachedTo: parent
        )
    }

    fileprivate func applyScalePreset(_ preset: ScalePreset) {
        session.perform(.applyScalePreset(preset), origin: .user)
    }

    fileprivate func reproject(onto referenceIdx: Int) {
        performImageCommand(.reproject(referenceIdx))
    }

}
