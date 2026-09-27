import Foundation

public struct LightCurvePoint: Sendable, Equatable {
    public let time: Double
    public let flux: Double
    public let err: Double

    public init(time: Double, flux: Double, err: Double) {
        self.time = time
        self.flux = flux
        self.err = err
    }
}

/// Display and export values for a cross-frame light curve.
public struct LightCurveModel: Sendable {
    public let points: [LightCurvePoint]
    public let timeLabel: String
    public var normalized: Bool
    private let normalizationMedian: Double

    public init(points: [LightCurvePoint], timeLabel: String, normalized: Bool = false) {
        self.points = points
        self.timeLabel = timeLabel
        self.normalized = normalized
        let sorted = points.map(\.flux).filter(\.isFinite).sorted()
        self.normalizationMedian = sorted.isEmpty ? 1 : sorted[sorted.count / 2]
    }

    public var displayedPoints: [LightCurvePoint] {
        guard normalized, normalizationMedian != 0 else { return points }
        return points.map { point in
            LightCurvePoint(time: point.time,
                            flux: point.flux / normalizationMedian,
                            err: point.err / abs(normalizationMedian))
        }
    }

    public var yLabel: String { normalized ? "flux / median" : "flux" }

    /// CSV always exports the measured values, independent of display normalization.
    public var csv: String {
        (["time,flux,err"] + points.map { "\($0.time),\($0.flux),\($0.err)" })
            .joined(separator: "\n")
    }
}
