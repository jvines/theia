import SwiftUI
import AppKit
import FITSCore
import FITSRender
import TheiaKit

struct DocumentView: View {
    let document: DocumentModel
    @ObservedObject var toolbarState: ToolbarState
    let toolbarController: FITSToolbarController
    let pixelTableBridge: PixelTableCursorBridge

    @State var session: DocumentSession
    @State var autosaveWatcher: SessionAutosaveWatcher
    @State var staleSession: SessionState?
    @State var persistenceWarning: String?
    let viewport: ImageViewState
    let interaction: InteractionController

    var stretch: ImageStretch {
        get { session.view.stretch }
        nonmutating set { session.perform(.setStretch(newValue), origin: .user) }
    }
    var colorMap: ColorMap {
        get { session.view.colorMap }
        nonmutating set { session.perform(.setColormap(newValue), origin: .user) }
    }
    var regions: [Region] {
        get { session.regions }
        nonmutating set { session.regions = newValue }
    }
    var selectedRegionIndex: Int? {
        get { session.selectedRegionIndex }
        nonmutating set { session.selectedRegionIndex = newValue }
    }
    private var previewRegion: Region? {
        get { session.previewRegion }
        nonmutating set { session.previewRegion = newValue }
    }
    var showWCSGrid: Bool {
        get { session.showGrid }
        nonmutating set { session.perform(.setGridVisible(newValue), origin: .user) }
    }
    var showCompass: Bool {
        get { session.showCompass }
        nonmutating set { session.perform(.setCompassVisible(newValue), origin: .user) }
    }
    var showColorBar: Bool {
        get { session.showColorBar }
        nonmutating set { session.perform(.setColorBarVisible(newValue), origin: .user) }
    }
    var contourSpec: ContourSpec {
        get { session.contourSpec }
        nonmutating set { session.perform(.setContourSpec(newValue), origin: .user) }
    }
    private var contourSegments: [Contours.LeveledSegments] { session.contourSegments }
    var drawMode: DrawMode {
        get { session.mode }
        nonmutating set { session.perform(.setDrawMode(newValue), origin: .user) }
    }
    var profileGeometry: ProfileGeometry? {
        get { session.profileMarker }
        nonmutating set { session.profileMarker = newValue }
    }
    var cursor: CursorInfo? {
        get { session.cursor }
        nonmutating set { session.cursor = newValue }
    }
    private var showInspector: Bool {
        get { session.inspectorVisible }
        nonmutating set { session.inspectorVisible = newValue }
    }
    var isFetchingCatalog: Bool {
        get { session.catalogFetchInProgress }
    }
    private var planePlaying: Bool {
        get { session.playing }
        nonmutating set { session.perform(.setPlaying(newValue), origin: .user) }
    }
    var blinkState: BlinkState? { session.blink }
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

    var selectedHDU: Int {
        get { session.hdu }
        nonmutating set { session.perform(.selectHDU(newValue), origin: .user) }
    }
    var selectedPlane: Int {
        get { session.plane }
        nonmutating set { session.perform(.selectPlane(newValue), origin: .user) }
    }
    var activeWCSVariant: String {
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
            .onAppear { onDocumentAppear() }
            .onDisappear { onDocumentDisappear() }
            .background(DocumentKeyEventMonitor(interaction: interaction))
            .overlay(alignment: .top) { persistenceNotices }
            // Collapse 11 toolbar-trigger .onChange entries into a single
            // snapshot-driven .onChange. Cuts the SwiftUI type-checker load
            // on this body and centralises the dependency list.
            .onChange(of: toolbarSyncSnapshot) { _, _ in syncToolbarState() }
            .onChange(of: imageRevision) { _, revision in onImageRevisionChange(revision) }
            .onChange(of: session.sourceDetectionNoticeID) { _, _ in showSourceDetectionNotice() }
            .onChange(of: session.catalogNoticeID) { _, _ in showCatalogNotice() }
            .onChange(of: session.imageOperationNoticeID) { _, _ in showImageOperationNotice() }
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

    @ViewBuilder
    private func makeImageView(hdu: FITSHDU) -> some View {
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
