import Foundation
import FITSCore

/// Per-document persisted state. New saves live in SessionStore; legacy
/// `<file>.session.json` sidecars remain readable during migration.
/// Optional fields may be absent from older session files.
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
    public var drawMode: DrawMode
    public var vmin: Double
    public var vmax: Double
    public var stretchParameter: Double
    public var showWCSGrid: Bool
    public var showCompass: Bool
    public var showColorBar: Bool
    public var regions: [Region]
    public var contour: Contour?

    public init(selectedHDU: Int, selectedPlane: Int, stretch: ImageStretch, colorMap: ColorMap,
                drawMode: DrawMode, vmin: Double, vmax: Double, stretchParameter: Double,
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
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return try encoder.encode(self)
    }

    public static func fromJSON(_ data: Data) throws -> SessionState {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return try decoder.decode(SessionState.self, from: data)
    }

    public static func sidecarURL(for fitsURL: URL) -> URL {
        let name = fitsURL.lastPathComponent + ".session.json"
        return fitsURL.deletingLastPathComponent().appendingPathComponent(name)
    }
}

extension DrawMode: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // Older SessionState stored arbitrary strings and ignored unknown modes
        // when restoring a new session, whose initial mode is pan.
        self = DrawMode(rawValue: value) ?? .pan
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
