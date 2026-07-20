import Foundation
import simd

/// Affine transform from image-pixel space to view-point space: `view = scale * imagePoint + translation`.
/// Used by the renderer (as Metal uniform) and by gesture handlers.
public struct ViewportTransform: Sendable, Equatable {
    /// 1.0 means one image pixel renders as one view point.
    public var scale: Double
    /// View-space coordinates of the image origin (top-left of pixel (0, 0)).
    public var translation: SIMD2<Double>

    public init(scale: Double = 1.0, translation: SIMD2<Double> = .zero) {
        self.scale = scale
        self.translation = translation
    }

    /// Largest uniform scale that fits `imageSize` inside `viewSize`, centered.
    public static func fit(imageSize: SIMD2<Double>, viewSize: SIMD2<Double>) -> ViewportTransform {
        let scaleX = viewSize.x / imageSize.x
        let scaleY = viewSize.y / imageSize.y
        let scale = min(scaleX, scaleY)
        let scaledW = imageSize.x * scale
        let scaledH = imageSize.y * scale
        let translation = SIMD2((viewSize.x - scaledW) / 2, (viewSize.y - scaledH) / 2)
        return ViewportTransform(scale: scale, translation: translation)
    }

    /// Multiply the current scale by `factor`, keeping the image point under `anchor` fixed in view space.
    public mutating func zoom(by factor: Double, around anchor: SIMD2<Double>) {
        let imagePoint = (anchor - translation) / scale
        scale *= factor
        translation = anchor - imagePoint * scale
    }

    public mutating func pan(by delta: SIMD2<Double>) {
        translation += delta
    }

    /// Maps a view-space point back to image-pixel space. Returns `.zero` if `scale == 0`.
    public func inverse(_ viewPoint: SIMD2<Double>) -> SIMD2<Double> {
        guard scale != 0 else { return .zero }
        return (viewPoint - translation) / scale
    }
}
