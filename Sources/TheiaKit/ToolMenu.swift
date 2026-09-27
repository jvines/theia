import Foundation
import FITSCore

public enum StackMode: String, CaseIterable, Sendable {
    case sum, mean, median

    public var label: String { rawValue.capitalized }
}

public enum FilterSpec: Sendable, Equatable {
    case boxcar(size: Int)
    case median(size: Int)
    case gaussian(sigma: Double)
}

/// The Tools menu's image operations are still carried out by the Mac shell.
/// This typed intent keeps the menu structure and enablement in the shared layer
/// while those operations move into DocumentSession in migration step 8.
public enum ToolMenuAction: Sendable, Equatable {
    case collapse(FITSImage.CollapseMode)
    case extractSlab
    case exportCube
    case stack(StackMode)
    case lightCurve
    case detectSources
    case crop
    case filter(FilterSpec)
    case unary(ImageArithmetic.UnaryOp)
    case subtractBackground
    case bin(Int)
    case reproject(Int)
    case binary(ImageArithmetic.BinaryOp, Int)
    case clearDerivedImage
}

public enum ToolMenuSection: String, Sendable, Equatable {
    case collapseCube = "Collapse cube"
    case stackAcrossWindows = "Stack across windows"
    case analysis = "Analysis"
    case filter = "Filter"
    case transform = "Transform"
    case reprojectOnto = "Reproject onto"
    case arithmeticVs = "Arithmetic vs"

    public var title: String { rawValue }
}

public struct ToolMenuItem: Sendable {
    public let identifier: String
    public let title: String
    public let section: ToolMenuSection?
    public let tooltip: String
    public let shortcut: CommandShortcut?
    public let enabled: Bool
    public let visible: Bool
    public let state: CommandSelectionState
    public let action: ToolMenuAction?
    public let children: [ToolMenuItem]
}

public enum ToolMenuEntry: Sendable {
    case section(ToolMenuSection)
    case item(ToolMenuItem)
    case separator

    public var section: ToolMenuSection? {
        if case .section(let value) = self { return value }
        return nil
    }

    public var item: ToolMenuItem? {
        if case .item(let value) = self { return value }
        return nil
    }
}

extension CommandCatalog {
    public static func toolsMenu(
        for session: DocumentSession, workspaceImageCount: Int
    ) -> [ToolMenuEntry] {
        let image = session.displayed
        let hasCube = session.file.hdus[session.hdu].naxis == 3
        var entries: [ToolMenuEntry] = []

        func item(
            _ id: String, _ title: String, _ section: ToolMenuSection?,
            _ action: ToolMenuAction?, enabled: Bool = true,
            children: [ToolMenuItem] = []
        ) -> ToolMenuItem {
            ToolMenuItem(identifier: id, title: title, section: section,
                         tooltip: title, shortcut: nil, enabled: enabled, visible: true,
                         state: .none,
                         action: action, children: children)
        }

        if hasCube {
            entries.append(.section(.collapseCube))
            for mode in FITSImage.CollapseMode.allCases {
                entries.append(.item(item("tools.collapse.\(mode.rawValue)", mode.label,
                                          .collapseCube, .collapse(mode))))
            }
            entries.append(.item(item("tools.extractSlab", "Extract slab (planes…)",
                                      .collapseCube, .extractSlab)))
            entries.append(.item(item("tools.exportCube", "Export cube as MP4…",
                                      .collapseCube, .exportCube)))
        }

        entries.append(.section(.stackAcrossWindows))
        for mode in StackMode.allCases {
            entries.append(.item(item("tools.stack.\(mode.rawValue)", "Stack: \(mode.label)",
                                      .stackAcrossWindows, .stack(mode),
                                      enabled: workspaceImageCount >= 2)))
        }
        entries.append(.item(item("tools.lightCurve", "Light curve (selected region)",
                                  .stackAcrossWindows, .lightCurve, enabled: image != nil)))

        if image != nil {
            entries.append(.section(.analysis))
            entries.append(.item(item("tools.detectSources", "Detect sources…",
                                      .analysis, .detectSources)))
            entries.append(.item(item("tools.crop", "Crop to selected region",
                                      .analysis, .crop)))
            entries.append(.section(.filter))
            for sigma in [1.0, 2.0, 4.0] {
                entries.append(.item(item("tools.filter.gaussian.\(Int(sigma))",
                                          "Gaussian σ=\(Int(sigma))", .filter,
                                          .filter(.gaussian(sigma: sigma)))))
            }
            for size in [3, 5, 7] {
                entries.append(.item(item("tools.filter.boxcar.\(size)",
                                          "Boxcar \(size)×\(size)", .filter,
                                          .filter(.boxcar(size: size)))))
            }
            for size in [3, 5] {
                entries.append(.item(item("tools.filter.median.\(size)",
                                          "Median \(size)×\(size)", .filter,
                                          .filter(.median(size: size)))))
            }
            entries.append(.section(.transform))
            for op in ImageArithmetic.UnaryOp.allCases {
                entries.append(.item(item("tools.unary.\(op.rawValue)", op.label,
                                          .transform, .unary(op))))
            }
            entries.append(.item(item("tools.subtractBackground",
                                      "Subtract background (3σ-clipped)",
                                      .transform, .subtractBackground)))
            for size in [2, 3, 4] {
                entries.append(.item(item("tools.bin.\(size)", "Bin \(size)×\(size)",
                                          .transform, .bin(size))))
            }
        }

        let candidates = session.file.hdus.indices.filter { index in
            index != session.hdu && session.file.hdus[index].isImage
                && session.file.hdus[index].naxis == 2
        }
        if !candidates.isEmpty {
            entries.append(.section(.reprojectOnto))
            for index in candidates {
                let label = DocumentText.hduLabel(index: index, name: session.file.hdus[index].name)
                let available = session.displayedWCS != nil
                    && session.facts[index].wcs(variant: "") != nil
                entries.append(.item(item("tools.reproject.\(index)", label,
                                          .reprojectOnto, .reproject(index), enabled: available)))
            }
            entries.append(.section(.arithmeticVs))
            for index in candidates {
                let label = DocumentText.hduLabel(index: index, name: session.file.hdus[index].name)
                let shape = session.facts[index].shape
                let available = image != nil && shape?.x == image?.width
                    && shape?.y == image?.height
                let children = ImageArithmetic.BinaryOp.allCases.map { op in
                    item("tools.arithmetic.\(index).\(op.rawValue)", op.label,
                         .arithmeticVs, .binary(op, index), enabled: available)
                }
                entries.append(.item(item("tools.arithmetic.\(index)", label,
                                          .arithmeticVs, nil, enabled: available,
                                          children: children)))
            }
        }

        if session.derived != nil {
            entries.append(.separator)
            entries.append(.item(item("tools.showOriginal", "Show original", nil,
                                      .clearDerivedImage)))
        }
        return entries
    }
}
