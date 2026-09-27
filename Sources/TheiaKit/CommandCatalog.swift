import Foundation
import FITSCore

public enum CommandSelectionState: Sendable, Equatable {
    case none
    case checked(Bool)
    case selected(String)
}

public struct CommandDescriptor: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let tooltip: String
    public let enabled: Bool
    public let state: CommandSelectionState
    public let command: SessionCommand?
}

public struct CommandMenuItem: Sendable {
    public let identifier: String
    public let title: String
    public let enabled: Bool
    public let state: CommandSelectionState
    public let command: SessionCommand?
    public let shortcut: CommandShortcut?
}

public struct CommandShortcut: Sendable, Equatable {
    /// The primary modifier maps to Command on macOS and Control on Linux.
    public let key: String
    public let shift: Bool

    public init(key: String, shift: Bool = false) {
        self.key = key
        self.shift = shift
    }
}

public enum WorkspaceMenuID: String, Sendable {
    case about
    case documentation
    case source
    case reportIssue
    case scriptingReference
    case welcome
    case onboarding
}

public enum WorkspaceMenuSection: Sendable {
    case app
    case help
    case sync
}

public struct WorkspaceMenuItem: Sendable {
    public let identifier: String
    public let title: String
    public let section: WorkspaceMenuSection
    public let tooltip: String
    public let shortcut: CommandShortcut?
    public let enabled: Bool
    public let visible: Bool
    public let state: CommandSelectionState
    public let command: WorkspaceCommand
}

public enum WorkspaceMenuEntry: Sendable {
    case item(WorkspaceMenuItem)
    case separator

    public var item: WorkspaceMenuItem? {
        if case .item(let value) = self { return value }
        return nil
    }
}

public enum ToolbarSlot: Sendable, Equatable {
    case item(String)
    case space
    case flexibleSpace
    case sidebarTrackingSeparator
}

public enum CommandMenuEntry: Sendable {
    case item(CommandMenuItem)
    case separator

    public var item: CommandMenuItem? {
        if case .item(let value) = self { return value }
        return nil
    }
}

/// Platform-neutral toolbar metadata and state. Identifiers match the Mac's
/// existing NSToolbarItem identifiers so saved toolbar layouts remain valid.
@MainActor public enum CommandCatalog {
    public static let defaultToolbarLayout: [ToolbarSlot] = [
        .item("stretch"), .item("map"), .item("mode"), .space,
        .item("zscale"), .item("scale"), .item("export"),
        .item("grid"), .item("compass"), .item("colorbar"),
        .item("pixeltable"), .item("contour"), .item("wcsVariant"),
        .item("blink"), .item("tools"), .item("catalog"), .item("sync"),
        .flexibleSpace, .item("header"),
    ]

    public static let extraAllowedToolbarSlots: [ToolbarSlot] = [
        .space, .flexibleSpace, .sidebarTrackingSeparator,
    ]

    public static func workspaceMenuItem(_ id: WorkspaceMenuID) -> WorkspaceMenuItem {
        func item(_ identifier: String, _ title: String, _ section: WorkspaceMenuSection,
                  _ command: WorkspaceCommand) -> WorkspaceMenuItem {
            WorkspaceMenuItem(identifier: identifier, title: title, section: section,
                              tooltip: title, shortcut: nil, enabled: true, visible: true,
                              state: .none, command: command)
        }
        switch id {
        case .about: return item("app.about", "About Theia", .app, .showAppWindow(.about))
        case .documentation:
            return item("help.documentation", "Theia Documentation", .help,
                        .openHelp(.documentation))
        case .source:
            return item("help.source", "Source on GitHub", .help, .openHelp(.source))
        case .reportIssue:
            return item("help.reportIssue", "Report an Issue…", .help,
                        .openHelp(.reportIssue))
        case .scriptingReference:
            return item("help.scriptingReference", "HTTP Scripting Reference", .help,
                        .showAppWindow(.scriptingReference))
        case .welcome:
            return item("help.welcome", "Open Welcome Window", .help,
                        .showAppWindow(.welcome))
        case .onboarding:
            return item("help.onboarding", "Show Onboarding", .help,
                        .showAppWindow(.onboarding))
        }
    }

    public static func workspaceMenu(
        section: WorkspaceMenuSection, for workspace: Workspace
    ) -> [WorkspaceMenuEntry] {
        switch section {
        case .app:
            return [.item(workspaceMenuItem(.about))]
        case .help:
            return [
                .item(workspaceMenuItem(.documentation)),
                .item(workspaceMenuItem(.source)),
                .item(workspaceMenuItem(.reportIssue)),
                .separator,
                .item(workspaceMenuItem(.scriptingReference)),
                .separator,
                .item(workspaceMenuItem(.welcome)),
                .item(workspaceMenuItem(.onboarding)),
            ]
        case .sync:
            func flag(_ value: SyncFlag, _ title: String, _ tooltip: String) -> WorkspaceMenuEntry {
                let checked = workspace.syncEnabled(value)
                return .item(WorkspaceMenuItem(
                    identifier: "sync.\(value.rawValue)", title: title, section: .sync,
                    tooltip: tooltip, shortcut: nil, enabled: true, visible: true,
                    state: .checked(checked), command: .setSyncFlag(value, !checked)
                ))
            }
            return [
                flag(.zoomPan, "Match zoom + pan", "Synchronise zoom and pan across windows"),
                flag(.scale, "Match scale (vmin/vmax)", "Synchronise brightness limits across windows"),
                flag(.colormap, "Match colormap", "Synchronise colour maps across windows"),
                flag(.crosshair, "Match crosshair (cursor)", "Show the cursor in other windows"),
                .separator,
                .item(WorkspaceMenuItem(
                    identifier: "sync.tileWindows", title: "Tile windows", section: .sync,
                    tooltip: "Arrange open windows side by side", shortcut: nil,
                    enabled: true, visible: true, state: .none, command: .tileWindows
                )),
            ]
        }
    }

    public static func viewMenu(for session: DocumentSession?) -> [CommandMenuEntry] {
        let enabled = session?.displayed != nil
        func item(_ id: String, _ title: String, _ command: SessionCommand,
                  key: String) -> CommandMenuEntry {
            .item(CommandMenuItem(identifier: id, title: title, enabled: enabled,
                                  state: .none, command: command,
                                  shortcut: CommandShortcut(key: key)))
        }
        return [
            item("view.fit", "Fit to Window", .fitView, key: "0"),
            item("view.actualSize", "Actual Size", .actualSize, key: "1"),
            item("view.zoomIn", "Zoom In", .zoomIn, key: "="),
            item("view.zoomOut", "Zoom Out", .zoomOut, key: "-"),
        ]
    }

    public static func imageMenu(for session: DocumentSession?) -> [CommandMenuEntry] {
        func item(_ id: String, _ toolbarID: String, _ title: String) -> CommandMenuEntry {
            let toolbar = session.flatMap { toolbarItem(toolbarID, for: $0) }
            return .item(CommandMenuItem(
                identifier: id, title: title, enabled: toolbar?.enabled ?? false,
                state: toolbar?.state ?? .none, command: toolbar?.command, shortcut: nil
            ))
        }
        return [
            item("image.zscale", "zscale", "ZScale"),
            .separator,
            item("image.grid", "grid", "WCS Grid"),
            item("image.compass", "compass", "Compass + Scale Bar"),
            item("image.colorBar", "colorbar", "Color Bar"),
            .separator,
            item("image.pixelTable", "pixeltable", "Pixel Table…"),
            item("image.contours", "contour", "Contour Levels…"),
        ]
    }

    public static func regionMenu(for session: DocumentSession?) -> [CommandMenuEntry] {
        let selected = session?.selectedRegionIndex.flatMap { index in
            session?.regions.indices.contains(index) == true ? index : nil
        }
        let hasRegions = !(session?.regions.isEmpty ?? true)
        func item(
            _ identifier: String, _ title: String, _ command: SessionCommand?,
            enabled: Bool, shortcut: CommandShortcut? = nil
        ) -> CommandMenuEntry {
            .item(CommandMenuItem(identifier: identifier, title: title, enabled: enabled,
                                  state: .none, command: command, shortcut: shortcut))
        }
        return [
            item("region.load", "Load Regions…", .loadRegions, enabled: session != nil),
            item("region.save", "Save Regions…", .saveRegions, enabled: hasRegions),
            .separator,
            item("region.delete", "Delete Selected Region", selected.map(SessionCommand.deleteRegion),
                 enabled: selected != nil),
            item("region.bringToFront", "Bring to Front", selected.map(SessionCommand.bringRegionToFront),
                 enabled: selected != nil),
            item("region.copy", "Copy as .reg Text", selected.map(SessionCommand.copyRegion),
                 enabled: selected != nil),
            .separator,
            item("region.clear", "Clear All Regions", .clearRegions, enabled: hasRegions),
            .separator,
            item("region.undo", "Undo Region Edit", .undoRegions,
                 enabled: session?.regionList.canUndo ?? false,
                 shortcut: CommandShortcut(key: "z")),
            item("region.redo", "Redo Region Edit", .redoRegions,
                 enabled: session?.regionList.canRedo ?? false,
                 shortcut: CommandShortcut(key: "z", shift: true)),
        ]
    }

    public static func analysisMenu(for session: DocumentSession?) -> [CommandMenuEntry] {
        let image = session?.displayed != nil
        let cube = session.map { $0.file.hdus[$0.hdu].naxis == 3 } ?? false
        func item(
            _ identifier: String, _ title: String, _ command: SessionCommand,
            enabled: Bool, checked: Bool
        ) -> CommandMenuEntry {
            .item(CommandMenuItem(identifier: identifier, title: title, enabled: enabled,
                                  state: .checked(checked), command: command, shortcut: nil))
        }
        func mode(_ value: DrawMode, _ title: String, enabled: Bool = true) -> CommandMenuEntry {
            item("analysis.\(value.rawValue)", title, .setDrawMode(value),
                 enabled: image && enabled, checked: session?.mode == value)
        }
        func panel(_ tab: InspectorTab, _ identifier: String, _ title: String) -> CommandMenuEntry {
            item(identifier, title, .showInspectorTab(tab), enabled: image,
                 checked: session?.inspectorVisible == true && session?.inspectorTab == tab)
        }
        return [
            mode(.lineProfile, "Line Profile"),
            mode(.radialProfile, "Radial Profile"),
            mode(.growthCurve, "Growth Curve"),
            mode(.measure, "Measure"),
            mode(.cubeSpectrum, "Cube Spectrum", enabled: cube),
            .separator,
            panel(.photometry, "analysis.photometry", "Photometry"),
            panel(.stats, "analysis.statistics", "Image Statistics"),
        ]
    }

    public static func sessionMenu(
        _ identifier: String, for session: DocumentSession
    ) -> [CommandMenuEntry]? {
        let image = session.displayed != nil
        func item(
            _ id: String, _ title: String, _ command: SessionCommand?,
            enabled: Bool = true, selected: Bool = false
        ) -> CommandMenuEntry {
            .item(CommandMenuItem(identifier: id, title: title, enabled: enabled,
                                  state: .checked(selected), command: command, shortcut: nil))
        }
        switch identifier {
        case "view": return viewMenu(for: session)
        case "stretch":
            return ImageStretch.allCases.map { value in
                item("stretch.\(value.rawValue)", value.label, .setStretch(value),
                     enabled: image, selected: session.view.stretch == value)
            }
        case "map":
            return ColorMap.allCases.map { value in
                item("map.\(value.rawValue)", value.label, .setColormap(value),
                     enabled: image, selected: session.view.colorMap == value)
            }
        case "mode":
            return DrawMode.allCases.map { value in
                item("mode.\(value.rawValue)", value.label, .setDrawMode(value),
                     enabled: image && (value != .cubeSpectrum
                         || session.file.hdus[session.hdu].naxis == 3),
                     selected: session.mode == value)
            }
        case "scale":
            let presets = ScalePreset.toolbarPresets.map { preset in
                item("scale.preset.\(preset.identifier)", preset.label, .applyScalePreset(preset),
                     enabled: image)
            }
            return presets + [
                .separator,
                item("scale.parameters", "Scale Parameters…", .showPanel(.scaleParameters),
                     enabled: image),
            ]
        case "wcsVariant":
            let variants = session.availableWCSVariants
            guard !variants.isEmpty else {
                return [item("wcs.empty", "No WCS in this HDU", nil, enabled: false)]
            }
            return variants.map { variant in
                let name = variant.isEmpty ? "Primary" : "Variant \(variant)"
                let title = session.wcsVariantLabels[variant].map { "\(name) — \($0)" } ?? name
                return item("wcs.\(variant.isEmpty ? "primary" : variant)", title,
                            .selectWCSVariant(variant), enabled: image && session.derived == nil,
                            selected: session.wcsVariant == variant)
            }
        default: return nil
        }
    }

    public static func toolbarItem(
        _ identifier: String, for session: DocumentSession, workspaceImageCount: Int = 0
    ) -> CommandDescriptor? {
        let image = session.displayed != nil
        let wcs = session.displayedWCS != nil
        func item(
            _ title: String, _ tooltip: String,
            enabled: Bool = true, state: CommandSelectionState = .none,
            command: SessionCommand? = nil
        ) -> CommandDescriptor {
            CommandDescriptor(identifier: identifier, title: title, tooltip: tooltip,
                              enabled: enabled, state: state, command: command)
        }
        switch identifier {
        case "stretch":
            return item("Stretch", "Image stretch function", enabled: image,
                        state: .selected(session.view.stretch.rawValue))
        case "map":
            return item("Map", "Colour map for stretched values", enabled: image,
                        state: .selected(session.view.colorMap.rawValue))
        case "mode":
            return item("Mode", "What the mouse does on the image", enabled: image,
                        state: .selected(session.mode.rawValue))
        case "zscale":
            return item("ZScale", "Reset brightness limits to zscale defaults", enabled: image,
                        command: .applyScalePreset(.zscale))
        case "scale":
            return item("Scale", "Choose vmin/vmax preset or open Scale Parameters…", enabled: image)
        case "export":
            return item("Export…", "Export current view as PNG or TIFF", enabled: image,
                        command: .exportImage)
        case "grid":
            return item("Grid", "Toggle WCS gridlines", enabled: wcs,
                        state: .checked(session.showGrid),
                        command: .setGridVisible(!session.showGrid))
        case "compass":
            return item("Compass", "Toggle compass + scale bar", enabled: wcs,
                        state: .checked(session.showCompass),
                        command: .setCompassVisible(!session.showCompass))
        case "colorbar":
            return item("Color Bar", "Toggle the color bar overlay", enabled: image,
                        state: .checked(session.showColorBar),
                        command: .setColorBarVisible(!session.showColorBar))
        case "pixeltable":
            return item("Pixel Table", "Open the pixel-value table at the cursor", enabled: image,
                        command: .showPanel(.pixelTable))
        case "contour":
            return item("Contours", "Open contour levels panel", enabled: image,
                        command: .showPanel(.contourLevels))
        case "sync":
            return item("Sync", "Synchronise zoom / scale / colormap across open windows")
        case "wcsVariant":
            return item("WCS", "Pick which WCS variant drives coordinates",
                        enabled: wcs && session.derived == nil && !session.availableWCSVariants.isEmpty,
                        state: .selected(session.wcsVariant))
        case "blink":
            return item("Blink", "Cycle between current HDU and next", enabled: session.blinkPartner != nil,
                        state: .checked(session.blink != nil), command: .toggleBlink)
        case "tools":
            return item("Tools", "Image analysis and stacking",
                        enabled: image || workspaceImageCount >= 2)
        case "catalog":
            return item("Catalog", "Fetch Gaia sources in field",
                        enabled: wcs && !session.catalogFetchInProgress)
        case "header":
            return item("Header", "Toggle header / regions inspector",
                        state: .checked(session.inspectorVisible),
                        command: .setInspectorVisible(!session.inspectorVisible))
        default: return nil
        }
    }
}
