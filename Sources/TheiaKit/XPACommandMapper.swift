import Foundation
import FITSCore

/// Only the document facts needed to answer a DS9-compatible xpaget command.
public struct XPADocumentSnapshot: Sendable, Equatable {
    public let id: Int
    public let path: String
    public let stretch: ImageStretch
    public let colorMap: ColorMap
    public let regions: [Region]
    public let zscaleContrast: Double

    public init(id: Int, path: String, stretch: ImageStretch,
                colorMap: ColorMap, regions: [Region],
                zscaleContrast: Double = PreferenceKeys.ZScaleContrast.defaultValue) {
        self.id = id
        self.path = path
        self.stretch = stretch
        self.colorMap = colorMap
        self.regions = regions
        self.zscaleContrast = zscaleContrast
    }
}

/// A parsed xpaset request. The host performs file and app actions; document
/// mutations go through the same SessionCommand path as menus and HTTP.
public enum XPAAction: Sendable, Equatable {
    case openFile(String)
    case session(SessionCommand)
    case quit
}

/// Why an XPA request was refused. Clients print the message after `XPA$ERROR`.
public struct XPARequestError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

public enum XPACommandMapper {
    /// The names `cmap` accepts, in menu order; DS9's "grey" is also accepted.
    public static var colorMapNames: [String] { ColorMap.allCases.map { $0.rawValue.lowercased() } }

    public static func get(command: String, params: String = "",
                           document: XPADocumentSnapshot?) -> Result<String, XPARequestError> {
        let tokens = params.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        switch command {
        case "version":
            return .success("Theia \(AppVersion.string)\(AppVersion.isBeta ? " (Beta)" : "")")
        case "frame":
            return .success(String((document?.id ?? -1) + 1))
        case "zscale":
            // DS9 answers `zscale contrast|sample|line`; a bare get gives the contrast.
            switch tokens.first {
            case nil, "contrast":
                return .success(String(document?.zscaleContrast
                                       ?? PreferenceKeys.ZScaleContrast.defaultValue))
            case "sample":
                return .success(String(PixelStatistics.zscaleSampleCount))
            case "line":
                return .failure(XPARequestError(
                    "Theia's zscale samples the whole image, so it has no line parameter"
                ))
            default:
                return .failure(XPARequestError("zscale: expected contrast, sample or line"))
            }
        default: break
        }
        guard let document else { return .failure(XPARequestError("no image is open")) }
        switch command {
        case "file": return .success(document.path)
        case "scale": return .success(ds9Scale(from: document.stretch))
        case "cmap": return .success(document.colorMap.rawValue.lowercased())
        case "regions": return .success(RegionFile.format(document.regions))
        default: return .failure(XPARequestError("Theia does not support xpaget \(command)"))
        }
    }

    public static func set(command: String, params: String,
                           data: Data?) -> Result<XPAAction, XPARequestError> {
        let value = params.trimmingCharacters(in: .whitespacesAndNewlines)
        switch command {
        case "file", "fits":
            let path = value.isEmpty ? stringFrom(data) : value
            guard let path, !path.isEmpty else {
                return .failure(XPARequestError("\(command): expected a file name"))
            }
            return .success(.openFile(path))
        case "scale":
            return scaleAction(value)
        case "cmap":
            guard let map = colorMap(named: value) else {
                return .failure(XPARequestError(
                    "unknown colour map '\(value)'; valid: \(colorMapNames.joined(separator: " "))"
                ))
            }
            return .success(.session(.setColormap(map)))
        case "zscale":
            guard value.isEmpty else {
                return .failure(XPARequestError(
                    "zscale \(value): contrast is set in Theia's Settings; sample and line are fixed"
                ))
            }
            return .success(.session(.applyScalePreset(.zscale)))
        case "regions":
            do {
                return .success(.session(.replaceRegions(try RegionFile.parse(stringFrom(data) ?? value))))
            } catch {
                return .failure(XPARequestError("regions: \(error.localizedDescription)"))
            }
        case "exit", "quit": return .success(.quit)
        default: return .failure(XPARequestError("Theia does not support xpaset \(command)"))
        }
    }

    private static let scaleUsage = "expected linear, log, pow, sqrt, squared, asinh, sinh, histequ, "
        + "mode minmax|zscale|<percent>, or limits <low> <high>"

    private static func scaleAction(_ value: String) -> Result<XPAAction, XPARequestError> {
        let tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
        switch tokens.first?.lowercased() {
        case "limits":
            guard tokens.count >= 3, let low = Double(tokens[1]), let high = Double(tokens[2]),
                  low.isFinite, high.isFinite, Float(low).isFinite, Float(high).isFinite else {
                return .failure(XPARequestError("scale limits: expected two finite numbers"))
            }
            return .success(.session(.setLevels(min: Float(low), max: Float(high))))
        case "mode":
            guard tokens.count >= 2 else {
                return .failure(XPARequestError("scale mode: expected minmax, zscale or a percentage"))
            }
            switch tokens[1].lowercased() {
            case "zscale": return .success(.session(.applyScalePreset(.zscale)))
            case "minmax": return .success(.session(.applyScalePreset(.minMax)))
            default:
                guard let percent = Double(tokens[1]), percent.isFinite,
                      percent > 0, percent <= 100 else {
                    return .failure(XPARequestError(
                        "scale mode \(tokens[1]): expected minmax, zscale or a percentage in (0, 100]"
                    ))
                }
                let tail = (100 - percent) / 2
                return .success(.session(.applyScalePreset(.percentile(lower: tail, upper: 100 - tail))))
            }
        default:
            guard let stretch = appStretch(from: value) else {
                return .failure(XPARequestError("scale '\(value)': \(scaleUsage)"))
            }
            return .success(.session(.setStretch(stretch)))
        }
    }

    private static func stringFrom(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appStretch(from value: String) -> ImageStretch? {
        switch value.lowercased() {
        case "pow", "power", "squared": return .power
        case "histequ", "histequal", "histogrameq": return .histogramEq
        default: return ImageStretch(rawValue: value.lowercased())
        }
    }

    private static func ds9Scale(from stretch: ImageStretch) -> String {
        switch stretch {
        case .power: return "pow"
        case .histogramEq: return "histequ"
        default: return stretch.rawValue
        }
    }

    /// Case-insensitive, like DS9, which also takes "grey" for gray.
    private static func colorMap(named value: String) -> ColorMap? {
        let name = value.lowercased()
        if name == "grey" { return .gray }
        return ColorMap.allCases.first { $0.rawValue.lowercased() == name }
    }
}
