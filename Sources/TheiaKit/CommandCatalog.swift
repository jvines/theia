import Foundation

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
}

/// Platform-neutral toolbar metadata and state. Identifiers match the Mac's
/// existing NSToolbarItem identifiers so saved toolbar layouts remain valid.
@MainActor public enum CommandCatalog {
    public static func toolbarItem(
        _ identifier: String, for session: DocumentSession, workspaceImageCount: Int = 0
    ) -> CommandDescriptor? {
        let image = session.displayed != nil
        let wcs = session.displayedWCS != nil
        func item(
            _ title: String, _ tooltip: String,
            enabled: Bool = true, state: CommandSelectionState = .none
        ) -> CommandDescriptor {
            CommandDescriptor(identifier: identifier, title: title, tooltip: tooltip,
                              enabled: enabled, state: state)
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
            return item("ZScale", "Reset brightness limits to zscale defaults", enabled: image)
        case "scale":
            return item("Scale", "Choose vmin/vmax preset or open Scale Parameters…", enabled: image)
        case "export":
            return item("Export…", "Export current view as PNG or TIFF", enabled: image)
        case "grid":
            return item("Grid", "Toggle WCS gridlines", enabled: wcs,
                        state: .checked(session.showGrid))
        case "compass":
            return item("Compass", "Toggle compass + scale bar", enabled: wcs,
                        state: .checked(session.showCompass))
        case "colorbar":
            return item("Color Bar", "Toggle the color bar overlay", enabled: image,
                        state: .checked(session.showColorBar))
        case "pixeltable":
            return item("Pixel Table", "Open the pixel-value table at the cursor", enabled: image)
        case "contour":
            return item("Contours", "Open contour levels panel", enabled: image)
        case "sync":
            return item("Sync", "Synchronise zoom / scale / colormap across open windows")
        case "wcsVariant":
            return item("WCS", "Pick which WCS variant drives coordinates",
                        enabled: wcs && !session.availableWCSVariants.isEmpty,
                        state: .selected(session.wcsVariant))
        case "blink":
            return item("Blink", "Cycle between current HDU and next", enabled: session.blinkPartner != nil,
                        state: .checked(session.blink != nil))
        case "tools":
            return item("Tools", "Image analysis and stacking",
                        enabled: image || workspaceImageCount >= 2)
        case "catalog":
            return item("Catalog", "Fetch Gaia sources in field",
                        enabled: wcs && !session.catalogFetchInProgress)
        case "header":
            return item("Header", "Toggle header / regions inspector",
                        state: .checked(session.inspectorVisible))
        default: return nil
        }
    }
}
