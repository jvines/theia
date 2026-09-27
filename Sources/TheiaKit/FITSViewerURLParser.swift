import Foundation
import FITSCore

/// Parsed `fitsviewer://open` request. The host opens the file, then applies
/// these settings through SessionCommand with script origin.
public struct FITSViewerURLRequest: Sendable {
    public let fileURL: URL
    private let stretch: ImageStretch?
    private let colorMap: ColorMap?
    private let vmin: Float?
    private let vmax: Float?
    private let zscale: Bool

    init(fileURL: URL, stretch: ImageStretch?, colorMap: ColorMap?,
         vmin: Float?, vmax: Float?, zscale: Bool) {
        self.fileURL = fileURL
        self.stretch = stretch
        self.colorMap = colorMap
        self.vmin = vmin
        self.vmax = vmax
        self.zscale = zscale
    }

    public func commands(currentVmin: Float, currentVmax: Float) -> [SessionCommand] {
        var commands: [SessionCommand] = []
        if let stretch { commands.append(.setStretch(stretch)) }
        if let colorMap { commands.append(.setColormap(colorMap)) }
        var lower = currentVmin
        var upper = currentVmax
        if let vmin {
            lower = vmin
            commands.append(.setLevels(min: lower, max: upper))
        }
        if let vmax {
            upper = vmax
            commands.append(.setLevels(min: lower, max: upper))
        }
        if zscale { commands.append(.applyScalePreset(.zscale)) }
        return commands
    }
}

public enum FITSViewerURLParser {
    public static func parse(_ url: URL) -> FITSViewerURLRequest? {
        guard url.scheme?.lowercased() == "fitsviewer", url.host?.lowercased() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/"), !path.isEmpty else { return nil }

        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        func finiteFloat(_ name: String) -> Float? {
            guard let raw = value(name), let number = Float(raw), number.isFinite else { return nil }
            return number
        }
        return FITSViewerURLRequest(
            fileURL: URL(fileURLWithPath: path),
            stretch: value("stretch").flatMap(ImageStretch.init(rawValue:)),
            colorMap: value("colormap").flatMap(ColorMap.init(rawValue:)),
            vmin: finiteFloat("vmin"), vmax: finiteFloat("vmax"),
            zscale: value("zscale") == "1"
        )
    }
}
