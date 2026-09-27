import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FITSCore
import FITSRender
import TheiaKit

extension Array {
    subscript(safe idx: Int) -> Element? {
        indices.contains(idx) ? self[idx] : nil
    }
}

extension DocumentView {
    func onDocumentAppear() {
        syncToolbarState()
        // Keep new edits even while an older stale session awaits a
        // decision; SessionStore preserves that archive separately.
        autosaveWatcher.start()
    }

    func onDocumentDisappear() {
        autosaveWatcher.close()
    }

    func onImageRevisionChange(_ revision: Int) {
        pixelTableBridge.imageRevision = revision
    }

    func showSourceDetectionNotice() {
        guard let title = session.sourceDetectionNoticeTitle,
              let message = session.sourceDetectionNoticeMessage else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    func showCatalogNotice() {
        guard let message = session.catalogErrorMessage else { return }
        let alert = NSAlert()
        alert.messageText = "Catalog fetch failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    func showImageOperationNotice() {
        guard let message = session.imageOperationErrorMessage else { return }
        applyEffect(.alert(title: "Image operation failed", message: message,
                           style: .warning))
    }

    func restoreStaleSession() {
        guard let staleSession else { return }
        autosaveWatcher.start()
        session.restoreInitialState(staleSession)
        self.staleSession = nil
        autosaveWatcher.schedule()
    }

    func dismissStaleSession() {
        do {
            try document.sessionStore.discardStale(for: document.url)
            staleSession = nil
            autosaveWatcher.start()
            autosaveWatcher.schedule()
        } catch {
            persistenceWarning = error.localizedDescription
        }
    }

    func handleKey(_ key: KeyEvent.Key, modifiers: EventModifiers) -> KeyPress.Result {
        var input: PointerEvent.Modifiers = []
        if modifiers.contains(.shift) { input.insert(.shift) }
        if modifiers.contains(.command) { input.insert(.primary) }
        if modifiers.contains(.option) { input.insert(.option) }
        if modifiers.contains(.control) { input.insert(.control) }
        return interaction.key(KeyEvent(key: key, modifiers: input)) ? .handled : .ignored
    }

    func syncToolbarState() {
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

    func handleLineProfile(from: SIMD2<Double>, to: SIMD2<Double>) {
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

    func handleRadialProfile(center: SIMD2<Double>, radius: Double) {
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

    func handleMeasure(from: SIMD2<Double>, to: SIMD2<Double>) {
        let measurement = Measurements.between(from: from, to: to, wcs: session.displayedWCS)
        let alert = NSAlert()
        alert.messageText = "Measurement"
        alert.informativeText = measurement.lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.runModal()
    }

    func handleGrowthCurve(center: SIMD2<Double>, radius: Double) {
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

    func handleCubeSpectrum(at p: SIMD2<Double>) {
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

    func handleCursor(_ info: CursorInfo?) {
        cursor = info
        pixelTableBridge.cursor = info
    }

    private func updateRegion(idx: Int, region: Region) {
        session.perform(.updateRegion(idx, region), origin: .user)
    }

    func showRegionContextMenu(index: Int, event: NSEvent) {
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

    func currentImage() -> FITSImage? {
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
        let workspace = WindowSyncCoordinator.shared.workspace
        guard let id = workspace.id(of: session) else { return }
        let outcome = workspace.perform(.stack(documentID: id, mode: mode), origin: .user)
        if let failure = outcome.failure {
            applyEffect(.alert(title: "Stack failed", message: failure.message,
                               style: .warning))
        }
    }

    fileprivate func generateLightCurve() {
        let workspace = WindowSyncCoordinator.shared.workspace
        guard let id = workspace.id(of: session) else { return }
        let outcome = workspace.perform(.lightCurve(documentID: id), origin: .user)
        if let failure = outcome.failure {
            applyEffect(.alert(title: "Light curve unavailable", message: failure.message,
                               style: .warning))
            return
        }
        for effect in outcome.effects { applyEffect(effect) }
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

    func applyEffect(_ effect: Effect) {
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
        case .documentOpened, .noteRecent, .alert, .showAppWindow, .openLightCurve, .openURL,
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
