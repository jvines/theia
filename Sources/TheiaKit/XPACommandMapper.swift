import Foundation
import FITSCore

/// Only the document facts needed to answer a DS9-compatible xpaget command.
public struct XPADocumentSnapshot: Sendable, Equatable {
    public let id: Int
    public let path: String
    public let stretch: ImageStretch
    public let colorMap: ColorMap
    public let regions: [Region]

    public init(id: Int, path: String, stretch: ImageStretch,
                colorMap: ColorMap, regions: [Region]) {
        self.id = id
        self.path = path
        self.stretch = stretch
        self.colorMap = colorMap
        self.regions = regions
    }
}

/// A parsed xpaset request. The host performs file and app actions; document
/// mutations go through the same SessionCommand path as menus and HTTP.
public enum XPAAction: Sendable, Equatable {
    case openFile(String)
    case session(SessionCommand)
    case quit
}

public enum XPACommandMapper {
    public static func get(command: String, params: String = "",
                           document: XPADocumentSnapshot?) -> String? {
        switch command {
        case "version":
            return "Theia \(AppVersion.string)\(AppVersion.isBeta ? " (Beta)" : "")"
        case "file": return document?.path
        case "frame": return String((document?.id ?? -1) + 1)
        case "scale": return document.map { ds9Scale(from: $0.stretch) }
        case "cmap": return document?.colorMap.rawValue.lowercased()
        case "regions": return document.map { RegionFile.format($0.regions) }
        default: return nil
        }
    }

    public static func set(command: String, params: String, data: Data?) -> XPAAction? {
        let value = params.trimmingCharacters(in: .whitespacesAndNewlines)
        switch command {
        case "file", "fits":
            let path = value.isEmpty ? stringFrom(data) : value
            guard let path, !path.isEmpty else { return nil }
            return .openFile(path)
        case "scale":
            let tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
            switch tokens.first?.lowercased() {
            case "limits" where tokens.count >= 3:
                guard let low = Double(tokens[1]), let high = Double(tokens[2]),
                      low.isFinite, high.isFinite else { return nil }
                let lowLevel = Float(low)
                let highLevel = Float(high)
                guard lowLevel.isFinite, highLevel.isFinite else { return nil }
                return .session(.setLevels(min: lowLevel, max: highLevel))
            case "mode":
                guard tokens.count >= 2 else { return nil }
                switch tokens[1].lowercased() {
                case "zscale": return .session(.applyScalePreset(.zscale))
                case "minmax": return .session(.applyScalePreset(.minMax))
                default:
                    guard let percent = Double(tokens[1]), percent.isFinite,
                          percent > 0, percent <= 100 else { return nil }
                    let tail = (100 - percent) / 2
                    return .session(.applyScalePreset(.percentile(lower: tail, upper: 100 - tail)))
                }
            default:
                guard let stretch = appStretch(from: value) else { return nil }
                return .session(.setStretch(stretch))
            }
        case "cmap":
            guard let map = appColorMap(from: value) else { return nil }
            return .session(.setColormap(map))
        case "zscale": return .session(.applyScalePreset(.zscale))
        case "regions":
            guard let regions = try? RegionFile.parse(stringFrom(data) ?? value) else { return nil }
            return .session(.replaceRegions(regions))
        case "exit", "quit": return .quit
        default: return nil
        }
    }

    private static func stringFrom(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appStretch(from value: String) -> ImageStretch? {
        switch value.lowercased() {
        case "pow", "power", "squared": return .power
        case "histequal", "histogrameq": return .histogramEq
        default: return ImageStretch(rawValue: value.lowercased())
        }
    }

    private static func ds9Scale(from stretch: ImageStretch) -> String {
        switch stretch {
        case .power: return "pow"
        case .histogramEq: return "histequal"
        default: return stretch.rawValue
        }
    }

    private static func appColorMap(from value: String) -> ColorMap? {
        switch value.lowercased() {
        case "grey", "gray": return .gray
        default: return ColorMap(rawValue: value.lowercased())
        }
    }
}
