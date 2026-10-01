import Foundation
import FITSCore

/// Display levels shared by the CPU rasterizer and Metal. Invalid bounds have
/// one predictable fallback so neither renderer receives a non-finite range.
public struct RasterLevels: Sendable, Equatable {
    public let vmin: Float
    public let vmax: Float

    public init(vmin: Float, vmax: Float) {
        let span = vmax - vmin
        if vmin.isFinite, vmax.isFinite, span.isFinite, span > 0 {
            self.vmin = vmin
            self.vmax = vmax
        } else {
            self.vmin = 0
            self.vmax = 1
        }
    }

    public var range: Float { max(vmax - vmin, 1e-6) }
}

/// Float32 stretch formulation mirrored by Shaders.metal.
public enum RasterStretch {
    public static func apply(
        _ value: Float,
        stretch: ImageStretch,
        levels: RasterLevels,
        parameter: Float = 2,
        cdf: [Float]? = nil
    ) -> Float {
        if value.isNaN { return .nan }
        // Clamp before arithmetic or conversion: this also handles both infinities.
        let clamped = min(levels.vmax, max(levels.vmin, value))
        let x = (clamped - levels.vmin) / levels.range
        switch stretch {
        case .linear: return x
        case .log: return log10(1 + 9 * x)
        case .sqrt: return x.squareRoot()
        case .asinh: return asinh(10 * x) / asinh(Float(10))
        case .sinh: return sinh(3 * x) / sinh(Float(3))
        case .power: return pow(x, max(parameter, 1e-6))
        case .histogramEq:
            guard let cdf, !cdf.isEmpty else { return x }
            let index = Int((x * Float(cdf.count - 1)).rounded(.down))
            return cdf[min(cdf.count - 1, max(0, index))]
        }
    }
}

/// Builds the 256-bin display CDF from a sorted finite sample. Per-level work
/// is 257 binary searches rather than a full image scan.
public enum RasterCDF {
    public static let binCount = 256

    public static func make(sortedFiniteSample sample: [Float], levels: RasterLevels) -> [Float] {
        var cdf = [Float](repeating: 0, count: binCount)
        let first = lowerBound(sample, levels.vmin)
        let end = upperBound(sample, levels.vmax)
        let total = end - first
        guard total > 0 else { return cdf }

        for bin in 0..<binCount {
            let endIndex: Int
            if bin == binCount - 1 {
                endIndex = end
            } else {
                let fraction = Float(bin + 1) / Float(binCount)
                let edge = levels.vmin + (levels.vmax - levels.vmin) * fraction
                endIndex = lowerBound(sample, edge)
            }
            cdf[bin] = Float(endIndex - first) / Float(total)
        }
        return cdf
    }

    private static func lowerBound(_ values: [Float], _ target: Float) -> Int {
        var lo = 0
        var hi = values.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if values[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func upperBound(_ values: [Float], _ target: Float) -> Int {
        var lo = 0
        var hi = values.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if values[mid] <= target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
