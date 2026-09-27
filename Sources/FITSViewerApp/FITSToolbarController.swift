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
                menuItem.menu = buildSessionMenu("stretch")
            case ID.map:
                menuItem.menu = buildSessionMenu("map")
            case ID.mode:
                menuItem.menu = buildSessionMenu("mode")
            case ID.tools:
                menuItem.menu = buildToolsMenu()
            case ID.scale:
                menuItem.menu = buildSessionMenu("scale")
            case ID.sync:
                menuItem.menu = buildSyncMenu()
            case ID.wcsVariant:
                menuItem.menu = buildSessionMenu("wcsVariant")
            default: break
            }
        }
    }

    private func buildSyncMenu() -> NSMenu {
        let menu = NSMenu()
        for entry in CommandCatalog.workspaceMenu(
            section: .sync, for: WindowSyncCoordinator.shared.workspace
        ) {
            guard let descriptor = entry.item else {
                menu.addItem(.separator())
                continue
            }
            guard descriptor.visible else { continue }
            let item = NSMenuItem(title: descriptor.title,
                                  action: #selector(workspaceMenuAction(_:)),
                                  keyEquivalent: descriptor.shortcut?.key ?? "")
            item.identifier = NSUserInterfaceItemIdentifier(descriptor.identifier)
            item.toolTip = descriptor.tooltip
            item.isEnabled = descriptor.enabled
            if case .checked(let checked) = descriptor.state {
                item.state = checked ? .on : .off
            }
            item.target = self
            item.representedObject = WorkspaceCommandBox(descriptor.command)
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        CommandCatalog.defaultToolbarLayout.map(toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
            + CommandCatalog.extraAllowedToolbarSlots.map(toolbarIdentifier)
    }

    private func toolbarIdentifier(_ slot: ToolbarSlot) -> NSToolbarItem.Identifier {
        switch slot {
        case .item(let identifier): NSToolbarItem.Identifier(identifier)
        case .space: .space
        case .flexibleSpace: .flexibleSpace
        case .sidebarTrackingSeparator: .sidebarTrackingSeparator
        }
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.stretch:
            return makeMenu(id: id, symbol: "slider.horizontal.3",
                            menu: buildSessionMenu("stretch"))
        case ID.map:
            return makeMenu(id: id, symbol: "paintpalette",
                            menu: buildSessionMenu("map"))
        case ID.mode:
            return makeMenu(id: id, symbol: "hand.draw",
                            menu: buildSessionMenu("mode"))
        case ID.zscale:
            return makeButton(id: id, symbol: "wand.and.stars",
                              action: #selector(sessionToolbarAction(_:)))
        case ID.scale:
            return makeMenu(id: id, symbol: "slider.vertical.3",
                            menu: buildSessionMenu("scale"))
        case ID.export:
            return makeButton(id: id, symbol: "square.and.arrow.up",
                              action: #selector(sessionToolbarAction(_:)))
        case ID.grid:
            return makeButton(id: id, symbol: "grid.circle",
                              action: #selector(sessionToolbarAction(_:)))
        case ID.compass:
            return makeButton(id: id, symbol: "location.north",
                              action: #selector(sessionToolbarAction(_:)))
        case ID.colorbar:
            return makeButton(id: id, symbol: "barometer",
                              action: #selector(sessionToolbarAction(_:)))
        case ID.pixeltable:
            return makeButton(id: id, symbol: "tablecells",
                              action: #selector(sessionToolbarAction(_:)))
        case ID.contour:
            return makeButton(id: id, symbol: "circle.hexagonpath",
                              action: #selector(sessionToolbarAction(_:)))
        case ID.sync:
            return makeMenu(id: id, symbol: "rectangle.split.2x1",
                            menu: buildSyncMenu())
        case ID.wcsVariant:
            return makeMenu(id: id, symbol: "globe",
                            menu: buildSessionMenu("wcsVariant"))
        case ID.blink:
            return makeButton(id: id, symbol: "rectangle.on.rectangle",
                              action: #selector(sessionToolbarAction(_:)))
        case ID.tools:
            return makeMenu(id: id, symbol: "wrench.and.screwdriver",
                            menu: buildToolsMenu())
        case ID.catalog:
            return makeButton(id: id, symbol: "sparkles",
                              action: #selector(catalogAction))
        case ID.header:
            return makeButton(id: id, symbol: "sidebar.right",
                              action: #selector(sessionToolbarAction(_:)))
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

    private func buildSessionMenu(_ identifier: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in CommandCatalog.sessionMenu(identifier, for: state.session) ?? [] {
            guard let descriptor = entry.item else {
                menu.addItem(.separator())
                continue
            }
            let mi = NSMenuItem(title: descriptor.title, action: #selector(sessionMenuAction(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = descriptor.command.map(SessionCommandBox.init)
            mi.isEnabled = descriptor.enabled
            if case .checked(let checked) = descriptor.state {
                mi.state = checked ? .on : .off
            }
            menu.addItem(mi)
        }
        return menu
    }

    private func buildToolsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in CommandCatalog.toolsMenu(
            for: state.session, workspaceImageCount: workspaceImageCount
        ) {
            switch entry {
            case .section(let section):
                menu.addItem(.sectionHeader(title: section.title))
            case .separator:
                menu.addItem(.separator())
            case .item(let descriptor):
                guard descriptor.visible else { continue }
                menu.addItem(makeToolMenuItem(descriptor))
            }
        }
        return menu
    }

    private func makeToolMenuItem(_ descriptor: ToolMenuItem) -> NSMenuItem {
        let item = NSMenuItem(title: descriptor.title,
                              action: descriptor.action == nil ? nil : #selector(toolMenuAction(_:)),
                              keyEquivalent: descriptor.shortcut?.key ?? "")
        item.identifier = NSUserInterfaceItemIdentifier(descriptor.identifier)
        item.toolTip = descriptor.tooltip
        item.keyEquivalentModifierMask = descriptor.shortcut?.shift == true
            ? [.command, .shift] : [.command]
        item.target = self
        item.isEnabled = descriptor.enabled
        if case .checked(let checked) = descriptor.state {
            item.state = checked ? .on : .off
        }
        item.representedObject = descriptor.action.map(ToolMenuActionBox.init)
        if !descriptor.children.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in descriptor.children where child.visible {
                submenu.addItem(makeToolMenuItem(child))
            }
            item.submenu = submenu
        }
        return item
    }

    // MARK: - Actions

    @objc private func sessionToolbarAction(_ sender: NSToolbarItem) {
        guard let descriptor = CommandCatalog.toolbarItem(
            sender.itemIdentifier.rawValue, for: state.session
        ), descriptor.enabled, let command = descriptor.command else { return }
        let outcome = state.session.perform(command, origin: .user)
        if outcome.failure == nil {
            for effect in outcome.effects { state.onEffect(effect) }
        }
    }
    @objc private func sessionMenuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SessionCommandBox else { return }
        let outcome = state.session.perform(box.command, origin: .user)
        if outcome.failure == nil {
            for effect in outcome.effects { state.onEffect(effect) }
        }
    }
    @objc private func workspaceMenuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? WorkspaceCommandBox else { return }
        AppDelegate.shared?.performWorkspaceCommand(box.command, origin: .user)
    }
    @objc private func catalogAction()       { state.onFetchCatalog() }
    @objc private func toolMenuAction(_ sender: NSMenuItem) {
        guard sender.isEnabled, let box = sender.representedObject as? ToolMenuActionBox else { return }
        switch box.action {
        case .collapse(let mode): state.onCollapseCube(mode)
        case .extractSlab:
            let outcome = state.session.perform(.extractSlab, origin: .user)
            if outcome.failure == nil {
                for effect in outcome.effects { state.onEffect(effect) }
            }
        case .exportCube:
            let outcome = state.session.perform(.exportCube, origin: .user)
            if outcome.failure == nil {
                for effect in outcome.effects { state.onEffect(effect) }
            }
        case .stack(let mode): state.onStackOpenDocuments(mode)
        case .lightCurve: state.onLightCurve()
        case .detectSources: state.onDetectSources()
        case .crop: state.onCropToSelection()
        case .filter(let spec): state.onApplyFilter(spec)
        case .unary(let op): state.onApplyUnary(op)
        case .subtractBackground: state.onSubtractBackground()
        case .bin(let size): state.onBinImage(size)
        case .reproject(let index): state.onReproject(index)
        case .binary(let op, let index): state.onApplyBinary(op, index)
        case .clearDerivedImage:
            _ = state.session.perform(.clearDerivedImage, origin: .user)
        }
    }
}

private final class SessionCommandBox: NSObject {
    let command: SessionCommand
    init(_ command: SessionCommand) { self.command = command }
}

private final class WorkspaceCommandBox: NSObject {
    let command: WorkspaceCommand
    init(_ command: WorkspaceCommand) { self.command = command }
}

private final class ToolMenuActionBox: NSObject {
    let action: ToolMenuAction
    init(_ action: ToolMenuAction) { self.action = action }
}
