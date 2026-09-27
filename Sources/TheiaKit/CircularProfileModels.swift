import Foundation
import Observation
import FITSCore

/// Shared controls and plot data for an azimuthally averaged image profile.
@MainActor @Observable public final class RadialProfileModel {
    public private(set) var radius: Double
    public private(set) var binWidth = 1.0
    public private(set) var xValues: [Double] = []
    public private(set) var yValues: [Double] = []
    public private(set) var isComputing = false
    public let maxAllowedRadius: Double

    @ObservationIgnored private let image: FITSImage
    @ObservationIgnored private let center: SIMD2<Double>
    @ObservationIgnored private let jobs = SessionJobQueue()
    @ObservationIgnored private var generation = 0

    public init(image: FITSImage, center: SIMD2<Double>, initialRadius: Double) {
        self.image = image
        self.center = center
        let initial = initialRadius.isFinite && initialRadius > 0 ? initialRadius : 1
        maxAllowedRadius = max(1, Double(min(image.width, image.height)), initial * 2)
        radius = min(max(initial, 1), maxAllowedRadius)
        recompute()
    }

    public func setRadius(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 1), maxAllowedRadius)
        guard radius != clamped else { return }
        radius = clamped
        recompute()
    }

    public func setBinWidth(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0.5), 10)
        guard binWidth != clamped else { return }
        binWidth = clamped
        recompute()
    }

    public func cancel() {
        generation &+= 1
        jobs.cancel(kind: .radialProfile)
        xValues = []
        yValues = []
        isComputing = false
    }

    private func recompute() {
        generation &+= 1
        let submittedGeneration = generation
        let image = image, center = center, radius = radius, binWidth = binWidth
        xValues = []
        yValues = []
        guard center.x.isFinite, center.y.isFinite else {
            jobs.cancel(kind: .radialProfile)
            isComputing = false
            return
        }
        isComputing = true
        jobs.enqueue(
            kind: .radialProfile, imageRevision: submittedGeneration,
            currentRevision: { [weak self] in self?.generation ?? -1 },
            work: {
                guard let bins = try? Profiles.radialProfileCheckingCancellation(
                    image: image, center: (center.x, center.y),
                    maxRadius: radius, binWidth: binWidth
                ) else { return nil }
                return CircularProfileData(xValues: bins.map(\.radius), yValues: bins.map(\.mean))
            },
            apply: { [weak self] (data: CircularProfileData) in
                self?.xValues = data.xValues
                self?.yValues = data.yValues
                self?.isComputing = false
            }
        )
    }

    public func idle() async { await jobs.idle() }
}

/// Shared controls and cumulative-flux plot data for an aperture growth curve.
@MainActor @Observable public final class GrowthCurveModel {
    public private(set) var radius: Double
    public private(set) var step = 1.0
    public private(set) var xValues: [Double] = []
    public private(set) var yValues: [Double] = []
    public private(set) var isComputing = false
    public let maxAllowedRadius: Double

    @ObservationIgnored private let image: FITSImage
    @ObservationIgnored private let center: SIMD2<Double>
    @ObservationIgnored private let jobs = SessionJobQueue()
    @ObservationIgnored private var generation = 0

    public init(image: FITSImage, center: SIMD2<Double>, initialRadius: Double) {
        self.image = image
        self.center = center
        let initial = initialRadius.isFinite && initialRadius > 0 ? initialRadius : 1
        maxAllowedRadius = max(1, Double(min(image.width, image.height)), initial * 2)
        radius = min(max(initial, 1), maxAllowedRadius)
        recompute()
    }

    public func setRadius(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 1), maxAllowedRadius)
        guard radius != clamped else { return }
        radius = clamped
        recompute()
    }

    public func setStep(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0.5), 10)
        guard step != clamped else { return }
        step = clamped
        recompute()
    }

    public func cancel() {
        generation &+= 1
        jobs.cancel(kind: .growthCurve)
        xValues = []
        yValues = []
        isComputing = false
    }

    private func recompute() {
        generation &+= 1
        let submittedGeneration = generation
        let image = image, center = center, radius = radius, step = step
        xValues = []
        yValues = []
        guard center.x.isFinite, center.y.isFinite else {
            jobs.cancel(kind: .growthCurve)
            isComputing = false
            return
        }
        isComputing = true
        jobs.enqueue(
            kind: .growthCurve, imageRevision: submittedGeneration,
            currentRevision: { [weak self] in self?.generation ?? -1 },
            work: {
                guard let points = try? Profiles.growthCurveCheckingCancellation(
                    image: image, center: (center.x, center.y),
                    maxRadius: radius, step: step
                ) else { return nil }
                return CircularProfileData(xValues: points.map(\.radius),
                                           yValues: points.map(\.cumulativeFlux))
            },
            apply: { [weak self] (data: CircularProfileData) in
                self?.xValues = data.xValues
                self?.yValues = data.yValues
                self?.isComputing = false
            }
        )
    }

    public func idle() async { await jobs.idle() }
}

private struct CircularProfileData: Sendable {
    let xValues: [Double]
    let yValues: [Double]
}
