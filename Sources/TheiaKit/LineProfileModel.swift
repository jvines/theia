import FITSCore

/// Plot data for a line drawn across the displayed image.
public struct LineProfileModel: Sendable {
    public let from: SIMD2<Double>
    public let to: SIMD2<Double>
    public let samples: [Profiles.LineSample]

    public init(image: FITSImage, from: SIMD2<Double>, to: SIMD2<Double>) {
        self.from = from
        self.to = to
        if from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite {
            samples = Profiles.lineProfile(
                image: image, from: (from.x, from.y), to: (to.x, to.y),
                samples: Self.sampleCount(from: from, to: to), interpolation: .bilinear
            )
        } else {
            samples = []
        }
    }

    public static func sampleCount(from: SIMD2<Double>, to: SIMD2<Double>) -> Int {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length.isFinite, length >= 0, length < Double(Int.max / 2) else {
            return 64
        }
        return Swift.max(64, Int(length.rounded(.up)) * 2)
    }

    public var xValues: [Double] { samples.map(\.distance) }
    public var yValues: [Double] { samples.map(\.value) }
}
