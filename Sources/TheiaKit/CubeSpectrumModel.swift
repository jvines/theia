import Foundation
import FITSCore

/// Spectral axis, Gaussian fit controls, and plot labels for a cube spectrum.
public struct CubeSpectrumModel: Sendable {
    public let title: String
    public let xLabel: String
    public let xs: [Double]
    public let ys: [Double]
    public let highlightX: Double?
    public var fitCenterText = ""
    public var fitHalfWidthText = ""
    public private(set) var fit: Gaussian1D.Result?

    public init(values: [Double], currentPlane: Int, label: String,
                xValues: [Double]?, xLabel: String) {
        self.title = "Cube spectrum — \(label)"
        self.xLabel = xLabel
        self.ys = values
        let supplied = xValues?.count == values.count ? xValues : nil
        self.xs = supplied ?? (0..<values.count).map(Double.init)
        if supplied == nil {
            self.highlightX = Double(currentPlane)
        } else {
            self.highlightX = self.xs.indices.contains(currentPlane) ? self.xs[currentPlane] : nil
        }
    }

    public var plotHighlight: Double? { fit?.center ?? highlightX }

    public var fitText: String? {
        guard let fit else { return nil }
        return String(format: "c=%.4g  σ=%.4g  FWHM=%.4g  amp=%.4g  bg=%.4g",
                      fit.center, fit.sigma, fit.fwhm, fit.amplitude, fit.baseline)
    }

    public mutating func runFit() {
        guard let center = Double(fitCenterText), let halfWidth = Double(fitHalfWidthText),
              center.isFinite, halfWidth.isFinite, halfWidth > 0 else { return }
        fit = Gaussian1D.fit(xs: xs, ys: ys, near: center, halfWidth: halfWidth)
    }

    public mutating func autoFit() {
        let span = abs((xs.last ?? 0) - (xs.first ?? 0))
        let halfWidth = Swift.max(span * 0.1, 1)
        var brightestX = xs.first ?? 0
        var brightestY = -Double.infinity
        for index in xs.indices where !ys[index].isNaN {
            if ys[index] > brightestY {
                brightestY = ys[index]
                brightestX = xs[index]
            }
        }
        let center = highlightX ?? brightestX
        fitCenterText = String(format: "%.4g", center)
        fitHalfWidthText = String(format: "%.4g", halfWidth)
        fit = Gaussian1D.fit(xs: xs, ys: ys, near: center, halfWidth: halfWidth)
    }
}
