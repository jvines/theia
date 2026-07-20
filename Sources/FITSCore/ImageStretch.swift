import Foundation

public enum ImageStretch: String, CaseIterable, Sendable {
    case linear
    case log
    case sqrt
    case asinh
    case power
    case histogramEq

    public var label: String {
        switch self {
        case .linear: return "Linear"
        case .log: return "Log"
        case .sqrt: return "Sqrt"
        case .asinh: return "Asinh"
        case .power: return "Power"
        case .histogramEq: return "Histogram Eq"
        }
    }

    /// Whether this stretch uses the scalar `parameter` argument.
    public var usesParameter: Bool {
        self == .power
    }

    /// Maps a pixel value into [0, 1] using the chosen stretch.
    /// - parameter parameter: scalar tuning knob — currently only used by `.power` as the exponent.
    /// - parameter cdf: CDF lookup table required by `.histogramEq`; ignored otherwise.
    /// NaN propagates.
    public func apply(_ value: Double, vmin: Double, vmax: Double, parameter: Double = 2.0, cdf: [Double]? = nil) -> Double {
        if value.isNaN { return .nan }
        let range = Swift.max(vmax - vmin, 1e-12)
        let x = Swift.max(0.0, Swift.min(1.0, (value - vmin) / range))
        switch self {
        case .linear:
            return x
        case .log:
            return log10(1 + 9 * x)
        case .sqrt:
            return x.squareRoot()
        case .asinh:
            return Foundation.asinh(10 * x) / Foundation.asinh(10.0)
        case .power:
            let exp = Swift.max(parameter, 1e-6)
            return Foundation.pow(x, exp)
        case .histogramEq:
            guard let cdf, !cdf.isEmpty else { return x }
            var idx = Int(x * Double(cdf.count - 1))
            idx = Swift.max(0, Swift.min(cdf.count - 1, idx))
            return cdf[idx]
        }
    }
}
