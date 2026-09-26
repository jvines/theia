import Foundation

/// View zoom and the image-space point shown at the centre of the view.
/// Image pixel centres have integer coordinates, with Y increasing upward.
public struct ViewTransform: Sendable, Equatable {
    /// View points per image pixel.
    public var scale: Double
    public var centre: SIMD2<Double>

    public init(scale: Double = 1, centre: SIMD2<Double> = .zero) {
        self.scale = scale
        self.centre = centre
    }

    public static func fit(imageSize: SIMD2<Double>, viewSize: SIMD2<Double>) -> ViewTransform {
        ViewTransform(
            scale: min(viewSize.x / imageSize.x, viewSize.y / imageSize.y),
            centre: (imageSize - SIMD2(repeating: 1)) / 2
        )
    }

    public mutating func zoom(by factor: Double, aroundImagePoint anchor: SIMD2<Double>) {
        guard factor > 0 else { return }
        centre = anchor + (centre - anchor) / factor
        scale *= factor
    }

    /// A positive Y delta moves the image down the view, so the image centre moves upward.
    public mutating func pan(by viewDelta: SIMD2<Double>) {
        centre.x -= viewDelta.x / scale
        centre.y += viewDelta.y / scale
    }
}
