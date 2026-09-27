import Foundation

/// Editable contour controls and their preview for a displayed image's data range.
public struct ContourLevelsModel: Sendable {
    public var spec: ContourSpec
    public var minText: String
    public var maxText: String
    public let dataMin: Double
    public let dataMax: Double

    public init(initial: ContourSpec, dataMin: Double, dataMax: Double) {
        var spec = initial
        spec.count = min(max(spec.count, 1), 32)
        if !spec.minValue.isFinite, dataMin.isFinite { spec.minValue = dataMin }
        if !spec.maxValue.isFinite, dataMax.isFinite { spec.maxValue = dataMax }
        self.spec = spec
        self.minText = Self.format(spec.minValue)
        self.maxText = Self.format(spec.maxValue)
        self.dataMin = dataMin
        self.dataMax = dataMax
    }

    public mutating func commitMin() {
        if let value = Self.parse(minText) {
            spec.minValue = value
        }
        minText = Self.format(spec.minValue)
    }

    public mutating func commitMax() {
        if let value = Self.parse(maxText) {
            spec.maxValue = value
        }
        maxText = Self.format(spec.maxValue)
    }

    public mutating func useDataRange() {
        if dataMin.isFinite {
            spec.minValue = dataMin
            minText = Self.format(dataMin)
        }
        if dataMax.isFinite {
            spec.maxValue = dataMax
            maxText = Self.format(dataMax)
        }
    }

    public var previewLevels: [Double] { spec.levels() }

    public var previewText: String {
        let levels = previewLevels
        guard !levels.isEmpty else { return "—" }
        return "levels: " + levels.map { String(format: "%.4g", $0) }.joined(separator: ", ")
    }

    public var dataRangeText: String? {
        guard dataMin.isFinite, dataMax.isFinite else { return nil }
        return String(format: "data %.3g … %.3g", dataMin, dataMax)
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func format(_ value: Double) -> String {
        if !value.isFinite { return "" }
        if abs(value) >= 1e4 || (value != 0 && abs(value) < 0.01) {
            return String(format: "%.4g", value)
        }
        return String(format: "%.4f", value)
    }
}
