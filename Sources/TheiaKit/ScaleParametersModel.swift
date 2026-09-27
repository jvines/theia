import Foundation
import FITSCore

/// Histogram, handle geometry, and editable values for a brightness-scale panel.
public struct ScaleParametersModel: Sendable {
    public static let presets = ScalePreset.toolbarPresets
    public static let powerExponentRange = 0.1...8.0

    public let dataMin: Double
    public let dataMax: Double
    public let valueCount: Int
    public let histogram: Histogram?
    public let barHeights: [Double]
    public var vminText: String
    public var vmaxText: String
    public var lowerPctText: String
    public var upperPctText: String

    public init(values: [Double], vmin: Double, vmax: Double,
                lowerPctText: String = "1", upperPctText: String = "99") {
        valueCount = values.count
        let finite = values.filter(\.isFinite)
        if let range = PixelStatistics.minMax(finite) {
            dataMin = range.min
            dataMax = range.max
            let span = range.max - range.min
            let binWidth = span / 256
            if range.min < range.max, span.isFinite,
               binWidth.isFinite, binWidth > 0 {
                let histogram = PixelStatistics.histogram(
                    finite, bins: 256, range: range.min...range.max
                )
                self.histogram = histogram
                let peak = histogram.counts.max() ?? 0
                let denominator = log10(Double(peak) + 1)
                barHeights = histogram.counts.map { count in
                    count > 0 && denominator > 0
                        ? log10(Double(count) + 1) / denominator : 0
                }
            } else {
                histogram = nil
                barHeights = []
            }
        } else {
            dataMin = .nan
            dataMax = .nan
            histogram = nil
            barHeights = []
        }
        vminText = Self.formatLevel(vmin)
        vmaxText = Self.formatLevel(vmax)
        self.lowerPctText = lowerPctText
        self.upperPctText = upperPctText
    }

    public mutating func refreshLevels(vmin: Double, vmax: Double) {
        vminText = Self.formatLevel(vmin)
        vmaxText = Self.formatLevel(vmax)
    }

    public var parsedVmin: Double? { Double(vminText) }
    public var parsedVmax: Double? { Double(vmaxText) }

    public var percentilePreset: ScalePreset? {
        guard let lower = Double(lowerPctText), let upper = Double(upperPctText) else {
            return nil
        }
        return .percentile(lower: lower, upper: upper)
    }

    public var stepSize: Double {
        guard dataMin.isFinite, dataMax.isFinite else { return 1 }
        let span = abs(dataMax - dataMin)
        guard span.isFinite else { return 1 }
        return max(span, 1e-9) / 200
    }

    public var dataRangeLabel: String {
        guard dataMin.isFinite, dataMax.isFinite else { return "Data range: —" }
        return String(format: "Data range: %.6g … %.6g", dataMin, dataMax)
    }

    public var histogramRangeLabel: String {
        guard dataMin.isFinite, dataMax.isFinite else { return "" }
        return "data \(Self.formatHistogramValue(dataMin)) … \(Self.formatHistogramValue(dataMax))"
    }

    public var histogramPlaceholder: String {
        if valueCount == 0 { return "No pixels to display" }
        if !dataMin.isFinite { return "No finite pixel values" }
        if dataMin != dataMax { return "Data range cannot be binned" }
        return "All finite pixels have the same value"
    }

    public func xForValue(_ value: Double, width: Double) -> Double {
        guard dataMax > dataMin, width.isFinite, width > 0 else { return 0 }
        let fraction = (value - dataMin) / (dataMax - dataMin)
        return max(0, min(1, fraction)) * width
    }

    public func valueForX(_ x: Double, width: Double) -> Double {
        guard width.isFinite, width > 0, dataMax > dataMin else { return dataMin }
        let fraction = max(0, min(width, x)) / width
        return dataMin + fraction * (dataMax - dataMin)
    }

    public func movedVmin(current: Double, vmax: Double,
                          deltaX: Double, width: Double) -> Double {
        let moved = valueForX(xForValue(current, width: width) + deltaX, width: width)
        let clamped = min(moved, vmax - 1e-9)
        let floatMax = Float(vmax)
        if floatMax.isFinite, Float(clamped) >= floatMax {
            return Double(floatMax.nextDown)
        }
        return clamped
    }

    public func movedVmax(current: Double, vmin: Double,
                          deltaX: Double, width: Double) -> Double {
        let moved = valueForX(xForValue(current, width: width) + deltaX, width: width)
        let clamped = max(moved, vmin + 1e-9)
        let floatMin = Float(vmin)
        if floatMin.isFinite, Float(clamped) <= floatMin {
            return Double(floatMin.nextUp)
        }
        return clamped
    }

    public func clampedPowerExponent(_ exponent: Double) -> Double {
        max(Self.powerExponentRange.lowerBound,
            min(Self.powerExponentRange.upperBound, exponent))
    }

    public static func formatHistogramValue(_ value: Double) -> String {
        if !value.isFinite { return "—" }
        if abs(value) >= 1e4 || (value != 0 && abs(value) < 0.01) {
            return String(format: "%.3e", value)
        }
        return String(format: "%.4g", value)
    }

    private static func formatLevel(_ value: Double) -> String {
        if !value.isFinite { return "—" }
        let magnitude = abs(value)
        if magnitude == 0 { return "0" }
        if magnitude >= 1000 || magnitude < 0.01 {
            return String(format: "%.4g", value)
        }
        return String(format: "%.4f", value)
    }
}
