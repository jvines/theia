/// The marker displayed for the latest profile request or its drag preview.
public enum ProfileGeometry: Equatable, Sendable {
    case line(from: SIMD2<Double>, to: SIMD2<Double>)
    case radial(center: SIMD2<Double>, maxRadius: Double)
    case growth(center: SIMD2<Double>, maxRadius: Double)
    case point(SIMD2<Double>)
}
