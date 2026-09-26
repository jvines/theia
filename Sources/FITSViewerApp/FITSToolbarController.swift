import AppKit
import Combine
import FITSCore
import FITSRender
import TheiaKit

/// Owns the document window's `NSToolbar`. Real `NSToolbarItem`s give native Cocoa
/// styling (matching Mail/Finder) and consistent behaviour across the Customize
/// Toolbar dialog's icon/text/both display modes.
@MainActor
final class FITSToolbarController: NSObject, NSToolbarDelegate {
    // Bump the version when the default item list changes — that invalidates the
    // user's autosaved customisation so they pick up any new items by default.
    static let toolbarIdentifier = NSToolbar.Identifier("cl.jvines.FITSViewer.toolbar.v4")

    private let state: ToolbarState
    private weak var toolbar: NSToolbar?
    private var cancellables: Set<AnyCancellable> = []

    init(state: ToolbarState) {
        self.state = state
        super.init()
        // Refresh validation + rebuild dynamic menus whenever state changes.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
    }

    private enum ID {
        static let stretch = NSToolbarItem.Identifier("stretch")
        static let map     = NSToolbarItem.Identifier("map")
        static let mode    = NSToolbarItem.Identifier("mode")
        static let zscale  = NSToolbarItem.Identifier("zscale")
        static let scale   = NSToolbarItem.Identifier("scale")
        static let export  = NSToolbarItem.Identifier("export")
        static let grid    = NSToolbarItem.Identifier("grid")
        static let compass = NSToolbarItem.Identifier("compass")
        static let colorbar = NSToolbarItem.Identifier("colorbar")
        static let pixeltable = NSToolbarItem.Identifier("pixeltable")
        static let contour = NSToolbarItem.Identifier("contour")
        static let sync = NSToolbarItem.Identifier("sync")
        static let wcsVariant = NSToolbarItem.Identifier("wcsVariant")
        static let blink   = NSToolbarItem.Identifier("blink")
        static let tools   = NSToolbarItem.Identifier("tools")
        static let catalog = NSToolbarItem.Identifier("catalog")
        static let header  = NSToolbarItem.Identifier("header")
    }

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: Self.toolbarIdentifier)
        tb.delegate = self
        tb.displayMode = .iconAndLabel
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        tb.isVisible = true
        toolbar = tb
        return tb
    }

    func refresh() {
        guard let tb = toolbar else { return }
        tb.validateVisibleItems()
        for item in tb.items {
            guard let menuItem = item as? NSMenuToolbarItem else { continue }
            switch item.itemIdentifier {
            case ID.stretch:
                menuItem.menu = buildSimpleMenu(ImageStretch.allCases,
                                                label: { $0.label },
                                                selected: state.stretch,
                                                action: #selector(stretchSelected(_:)))
            case ID.map:
                menuItem.menu = buildSimpleMenu(ColorMap.allCases,
                                                label: { $0.label },
                                                selected: state.colorMap,
                                                action: #selector(mapSelected(_:)))
            case ID.mode:
                menuItem.menu = buildSimpleMenu(DrawMode.allCases,
                                                label: { $0.label },
                                                selected: state.drawMode,
                                                action: #selector(modeSelected(_:)))
            case ID.tools:
                menuItem.menu = buildToolsMenu()
            case ID.scale:
                menuItem.menu = buildScaleMenu()
            case ID.sync:
                menuItem.menu = buildSyncMenu()
            case ID.wcsVariant:
                menuItem.menu = buildWCSVariantMenu()
            default: break
            }
        }
    }

    private func buildWCSVariantMenu() -> NSMenu {
        let menu = NSMenu()
        if state.wcsVariants.isEmpty {
            let mi = NSMenuItem(title: "No WCS in this HDU", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
            return menu
        }
        for v in state.wcsVariants {
            let label = v.isEmpty ? "Primary" : "Variant \(v)"
            let title: String
            if let nice = state.wcsVariantLabels[v] { title = "\(label) — \(nice)" }
            else { title = label }
            let mi = NSMenuItem(title: title, action: #selector(wcsVariantSelected(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = v as NSString
            mi.state = (v == state.activeWCSVariant) ? .on : .off
            menu.addItem(mi)
        }
        return menu
    }

    private func buildSyncMenu() -> NSMenu {
        let menu = NSMenu()
        let coord = WindowSyncCoordinator.shared
        let zoom = NSMenuItem(title: "Match zoom + pan", action: #selector(toggleMatchZoom), keyEquivalent: "")
        zoom.target = self
        zoom.state = coord.matchZoom ? .on : .off
        menu.addItem(zoom)
        let scale = NSMenuItem(title: "Match scale (vmin/vmax)", action: #selector(toggleMatchScale), keyEquivalent: "")
        scale.target = self
        scale.state = coord.matchScale ? .on : .off
        menu.addItem(scale)
        let map = NSMenuItem(title: "Match colormap", action: #selector(toggleMatchColormap), keyEquivalent: "")
        map.target = self
        map.state = coord.matchColormap ? .on : .off
        menu.addItem(map)
        let cross = NSMenuItem(title: "Match crosshair (cursor)", action: #selector(toggleMatchCrosshair), keyEquivalent: "")
        cross.target = self
        cross.state = coord.matchCrosshair ? .on : .off
        menu.addItem(cross)
        menu.addItem(.separator())
        let tile = NSMenuItem(title: "Tile windows", action: #selector(tileAction), keyEquivalent: "")
        tile.target = self
        menu.addItem(tile)
        return menu
    }

    private func buildScaleMenu() -> NSMenu {
        let menu = NSMenu()
        for p in ScalePreset.toolbarPresets {
            let mi = NSMenuItem(title: p.label, action: #selector(presetSelected(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ScalePresetBox(preset: p)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let params = NSMenuItem(title: "Scale Parameters…", action: #selector(openParametersAction), keyEquivalent: "")
        params.target = self
        menu.addItem(params)
        return menu
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ID.stretch, ID.map, ID.mode,
            .space,
            ID.zscale, ID.scale, ID.export,
            ID.grid, ID.compass, ID.colorbar, ID.pixeltable, ID.contour, ID.wcsVariant,
            ID.blink,
            ID.tools, ID.catalog, ID.sync,
            .flexibleSpace,
            ID.header,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace, .sidebarTrackingSeparator]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.stretch:
            return makeMenu(id: id, symbol: "slider.horizontal.3",
                            menu: buildSimpleMenu(ImageStretch.allCases, label: { $0.label },
                                                  selected: state.stretch,
                                                  action: #selector(stretchSelected(_:))))
        case ID.map:
            return makeMenu(id: id, symbol: "paintpalette",
                            menu: buildSimpleMenu(ColorMap.allCases, label: { $0.label },
                                                  selected: state.colorMap,
                                                  action: #selector(mapSelected(_:))))
        case ID.mode:
            return makeMenu(id: id, symbol: "hand.draw",
                            menu: buildSimpleMenu(DrawMode.allCases, label: { $0.label },
                                                  selected: state.drawMode,
                                                  action: #selector(modeSelected(_:))))
        case ID.zscale:
            return makeButton(id: id, symbol: "wand.and.stars",
                              action: #selector(zscaleAction))
        case ID.scale:
            return makeMenu(id: id, symbol: "slider.vertical.3",
                            menu: buildScaleMenu())
        case ID.export:
            return makeButton(id: id, symbol: "square.and.arrow.up",
                              action: #selector(exportAction))
        case ID.grid:
            return makeButton(id: id, symbol: "grid.circle",
                              action: #selector(gridAction))
        case ID.compass:
            return makeButton(id: id, symbol: "location.north",
                              action: #selector(compassAction))
        case ID.colorbar:
            return makeButton(id: id, symbol: "barometer",
                              action: #selector(colorBarAction))
        case ID.pixeltable:
            return makeButton(id: id, symbol: "tablecells",
                              action: #selector(pixelTableAction))
        case ID.contour:
            return makeButton(id: id, symbol: "circle.hexagonpath",
                              action: #selector(contourAction))
        case ID.sync:
            return makeMenu(id: id, symbol: "rectangle.split.2x1",
                            menu: buildSyncMenu())
        case ID.wcsVariant:
            return makeMenu(id: id, symbol: "globe",
                            menu: buildWCSVariantMenu())
        case ID.blink:
            return makeButton(id: id, symbol: "rectangle.on.rectangle",
                              action: #selector(blinkAction))
        case ID.tools:
            return makeMenu(id: id, symbol: "wrench.and.screwdriver",
                            menu: buildToolsMenu())
        case ID.catalog:
            return makeButton(id: id, symbol: "sparkles",
                              action: #selector(catalogAction))
        case ID.header:
            return makeButton(id: id, symbol: "sidebar.right",
                              action: #selector(headerAction))
        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        CommandCatalog.toolbarItem(item.itemIdentifier.rawValue, for: state.session,
                                   workspaceImageCount: workspaceImageCount)?.enabled ?? true
    }

    private var workspaceImageCount: Int {
        AppDelegate.shared?.allControllersForScripting().filter {
            $0.documentModel.session.displayed != nil
        }.count ?? 0
    }

    // MARK: - Factories

    private func makeButton(id: NSToolbarItem.Identifier,
                            symbol: String, action: Selector) -> NSToolbarItem {
        let descriptor = CommandCatalog.toolbarItem(id.rawValue, for: state.session)!
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = descriptor.title
        item.paletteLabel = descriptor.title
        item.toolTip = descriptor.tooltip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: descriptor.title)
        item.target = self
        item.action = action
        return item
    }

    private func makeMenu(id: NSToolbarItem.Identifier,
                          symbol: String, menu: NSMenu) -> NSMenuToolbarItem {
        let descriptor = CommandCatalog.toolbarItem(id.rawValue, for: state.session)!
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = descriptor.title
        item.paletteLabel = descriptor.title
        item.toolTip = descriptor.tooltip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: descriptor.title)
        item.menu = menu
        return item
    }

    private func buildSimpleMenu<T: Equatable>(_ values: [T],
                                               label: (T) -> String,
                                               selected: T,
                                               action: Selector) -> NSMenu {
        let menu = NSMenu()
        for v in values {
            let mi = NSMenuItem(title: label(v), action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = v
            mi.state = (v == selected) ? .on : .off
            menu.addItem(mi)
        }
        return menu
    }

    private func buildToolsMenu() -> NSMenu {
        let menu = NSMenu()
        if state.hasCube {
            menu.addItem(NSMenuItem.sectionHeader(title: "Collapse cube"))
            for mode in FITSImage.CollapseMode.allCases {
                let mi = NSMenuItem(title: mode.label, action: #selector(collapseSelected(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = CollapseModeBox(mode: mode)
                menu.addItem(mi)
            }
            let slab = NSMenuItem(title: "Extract slab (planes…)", action: #selector(slabAction), keyEquivalent: "")
            slab.target = self
            menu.addItem(slab)
            let mp4 = NSMenuItem(title: "Export cube as MP4…", action: #selector(exportMP4Action), keyEquivalent: "")
            mp4.target = self
            menu.addItem(mp4)
        }
        // Multi-document stacking.
        menu.addItem(NSMenuItem.sectionHeader(title: "Stack across windows"))
        for mode in StackMode.allCases {
            let mi = NSMenuItem(title: "Stack: \(mode.label)", action: #selector(stackAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue as NSString
            mi.isEnabled = workspaceImageCount >= 2
            menu.addItem(mi)
        }
        let lc = NSMenuItem(title: "Light curve (selected region)", action: #selector(lightCurveAction), keyEquivalent: "")
        lc.target = self
        lc.isEnabled = state.session.displayed != nil
        menu.addItem(lc)
        if state.hasSelectedImage {
            menu.addItem(NSMenuItem.sectionHeader(title: "Analysis"))
            let detect = NSMenuItem(title: "Detect sources…", action: #selector(detectSourcesAction), keyEquivalent: "")
            detect.target = self
            menu.addItem(detect)
            let crop = NSMenuItem(title: "Crop to selected region", action: #selector(cropAction), keyEquivalent: "")
            crop.target = self
            menu.addItem(crop)
            menu.addItem(NSMenuItem.sectionHeader(title: "Filter"))
            for (title, sigma) in [("Gaussian σ=1", 1.0), ("Gaussian σ=2", 2.0), ("Gaussian σ=4", 4.0)] {
                let mi = NSMenuItem(title: title, action: #selector(gaussianSelected(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = sigma as NSNumber
                menu.addItem(mi)
            }
            for n in [3, 5, 7] {
                let mi = NSMenuItem(title: "Boxcar \(n)×\(n)", action: #selector(boxcarSelected(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = n
                menu.addItem(mi)
            }
            for n in [3, 5] {
                let mi = NSMenuItem(title: "Median \(n)×\(n)", action: #selector(medianSelected(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = n
                menu.addItem(mi)
            }
            menu.addItem(NSMenuItem.sectionHeader(title: "Transform"))
            for op in ImageArithmetic.UnaryOp.allCases {
                let mi = NSMenuItem(title: op.label, action: #selector(unarySelected(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = UnaryOpBox(op: op)
                menu.addItem(mi)
            }
            // Background subtraction + bin.
            let subBg = NSMenuItem(title: "Subtract background (3σ-clipped)",
                                   action: #selector(subtractBgAction), keyEquivalent: "")
            subBg.target = self
            menu.addItem(subBg)
            for n in [2, 3, 4] {
                let mi = NSMenuItem(title: "Bin \(n)×\(n)", action: #selector(binAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = n
                menu.addItem(mi)
            }
        }
        if !state.reprojectCandidates.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Reproject onto"))
            for (idx, label, enabled) in state.reprojectCandidates {
                let mi = NSMenuItem(title: label, action: #selector(reprojectSelected(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = idx
                mi.isEnabled = enabled
                menu.addItem(mi)
            }
        }
        if !state.differenceCandidates.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Arithmetic vs"))
            for (idx, label, enabled) in state.differenceCandidates {
                let parent = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for op in ImageArithmetic.BinaryOp.allCases {
                    let mi = NSMenuItem(title: op.label, action: #selector(binarySelected(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = BinaryOpBox(op: op, otherIndex: idx)
                    mi.isEnabled = enabled
                    submenu.addItem(mi)
                }
                parent.submenu = submenu
                parent.isEnabled = enabled
                menu.addItem(parent)
            }
        }
        if state.hasDisplayOverride {
            menu.addItem(NSMenuItem.separator())
            let mi = NSMenuItem(title: "Show original", action: #selector(clearOverrideAction), keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        return menu
    }

    // MARK: - Actions

    @objc private func zscaleAction()        { state.onZScale() }
    @objc private func openParametersAction(){ state.onOpenScaleParameters() }
    @objc private func presetSelected(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ScalePresetBox else { return }
        state.onApplyScalePreset(box.preset)
    }
    @objc private func exportAction()        { state.onExport() }
    @objc private func gridAction()          { state.onToggleGrid() }
    @objc private func compassAction()       { state.onToggleCompass() }
    @objc private func colorBarAction()      { state.onToggleColorBar() }
    @objc private func pixelTableAction()    { state.onOpenPixelTable() }
    @objc private func contourAction()       { state.onOpenContourLevels() }
    @objc private func toggleMatchZoom()     { WindowSyncCoordinator.shared.matchZoom.toggle(); refresh() }
    @objc private func toggleMatchScale()    { WindowSyncCoordinator.shared.matchScale.toggle(); refresh() }
    @objc private func toggleMatchColormap() { WindowSyncCoordinator.shared.matchColormap.toggle(); refresh() }
    @objc private func toggleMatchCrosshair() {
        let c = WindowSyncCoordinator.shared
        c.matchCrosshair.toggle()
        if !c.matchCrosshair { c.clearCrosshairs() }
        refresh()
    }
    @objc private func tileAction()          { WindowSyncCoordinator.shared.tileWindowsHorizontally() }
    @objc private func blinkAction()         { state.onToggleBlink() }
    @objc private func catalogAction()       { state.onFetchCatalog() }
    @objc private func headerAction()        { state.onToggleInspector() }
    @objc private func clearOverrideAction() { state.onClearOverride() }

    @objc private func stretchSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? ImageStretch else { return }
        state.onSelectStretch(v)
    }
    @objc private func mapSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? ColorMap else { return }
        state.onSelectMap(v)
    }
    @objc private func modeSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? DrawMode else { return }
        state.onSelectMode(v)
    }
    @objc private func reprojectSelected(_ sender: NSMenuItem) {
        state.onReproject(sender.tag)
    }
    @objc private func differenceSelected(_ sender: NSMenuItem) {
        state.onDifference(sender.tag - 10_000)
    }
    @objc private func detectSourcesAction() { state.onDetectSources() }
    @objc private func cropAction()         { state.onCropToSelection() }
    @objc private func exportMP4Action()    { state.onExportCubeMP4() }
    @objc private func subtractBgAction()   { state.onSubtractBackground() }
    @objc private func binAction(_ sender: NSMenuItem) { state.onBinImage(sender.tag) }
    @objc private func slabAction()         { state.onCubeSlab(0, -1) }   // -1 = "prompt"
    @objc private func stackAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = StackMode(rawValue: raw) else { return }
        state.onStackOpenDocuments(m)
    }
    @objc private func lightCurveAction() { state.onLightCurve() }
    @objc private func wcsVariantSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        state.onSelectWCSVariant(v)
    }

    @objc private func collapseSelected(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CollapseModeBox else { return }
        state.onCollapseCube(box.mode)
    }
    @objc private func gaussianSelected(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        state.onApplyFilter(.gaussian(sigma: n.doubleValue))
    }
    @objc private func boxcarSelected(_ sender: NSMenuItem) {
        state.onApplyFilter(.boxcar(size: sender.tag))
    }
    @objc private func medianSelected(_ sender: NSMenuItem) {
        state.onApplyFilter(.median(size: sender.tag))
    }
    @objc private func unarySelected(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? UnaryOpBox else { return }
        state.onApplyUnary(box.op)
    }
    @objc private func binarySelected(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? BinaryOpBox else { return }
        state.onApplyBinary(box.op, box.otherIndex)
    }
}

final class CollapseModeBox: NSObject {
    let mode: FITSImage.CollapseMode
    init(mode: FITSImage.CollapseMode) { self.mode = mode }
}

final class UnaryOpBox: NSObject {
    let op: ImageArithmetic.UnaryOp
    init(op: ImageArithmetic.UnaryOp) { self.op = op }
}

final class BinaryOpBox: NSObject {
    let op: ImageArithmetic.BinaryOp
    let otherIndex: Int
    init(op: ImageArithmetic.BinaryOp, otherIndex: Int) { self.op = op; self.otherIndex = otherIndex }
}
