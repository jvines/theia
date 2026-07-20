import Foundation

/// Per-document persisted state. Stored next to the FITS file as a JSON sidecar
/// (`<file>.fits.session.json`) and auto-loaded on reopen.
///
/// Forward-compat: optional fields may be absent in older session files.
public struct SessionState: Codable, Equatable {
    public struct Contour: Codable, Equatable {
        public var enabled: Bool
        public var count: Int
        public var minValue: Double
        public var maxValue: Double
        public var spacing: String   // "linear" or "log"
        public init(enabled: Bool, count: Int, minValue: Double, maxValue: Double, spacing: String) {
            self.enabled = enabled; self.count = count
            self.minValue = minValue; self.maxValue = maxValue; self.spacing = spacing
        }
    }

    public var selectedHDU: Int
    public var selectedPlane: Int
    public var stretch: ImageStretch
    public var colorMap: ColorMap
    public var drawMode: String     // DrawMode.rawValue, stringly-typed to keep FITSCore free of FITSRender
    public var vmin: Double
    public var vmax: Double
    public var stretchParameter: Double
    public var showWCSGrid: Bool
    public var showCompass: Bool
    public var showColorBar: Bool
    public var regions: [Region]
    public var contour: Contour?

    public init(selectedHDU: Int, selectedPlane: Int, stretch: ImageStretch, colorMap: ColorMap,
                drawMode: String, vmin: Double, vmax: Double, stretchParameter: Double,
                showWCSGrid: Bool, showCompass: Bool, showColorBar: Bool,
                regions: [Region], contour: Contour? = nil) {
        self.selectedHDU = selectedHDU; self.selectedPlane = selectedPlane
        self.stretch = stretch; self.colorMap = colorMap; self.drawMode = drawMode
        self.vmin = vmin; self.vmax = vmax; self.stretchParameter = stretchParameter
        self.showWCSGrid = showWCSGrid; self.showCompass = showCompass; self.showColorBar = showColorBar
        self.regions = regions; self.contour = contour
    }

    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func fromJSON(_ data: Data) throws -> SessionState {
        try JSONDecoder().decode(SessionState.self, from: data)
    }

    public static func sidecarURL(for fitsURL: URL) -> URL {
        let name = fitsURL.lastPathComponent + ".session.json"
        return fitsURL.deletingLastPathComponent().appendingPathComponent(name)
    }
}

extension ImageStretch: Codable {}
extension ColorMap: Codable {}
