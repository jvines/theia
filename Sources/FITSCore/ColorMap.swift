import Foundation
import simd

/// Display colour maps for stretched pixel values in `[0, 1]`.
///
/// The non-trivial perceptual maps (viridis, magma, plasma) use the well-known
/// polynomial fits to matplotlib's listed colormaps by Mike Bostock and collected
/// on Shadertoy (https://www.shadertoy.com/view/WlfXRN). Negligible error from
/// the reference LUTs for our purposes.
public enum ColorMap: String, CaseIterable, Sendable {
    case gray
    case invertedGray
    case viridis
    case magma
    case plasma

    public var label: String {
        switch self {
        case .gray: return "Gray"
        case .invertedGray: return "Inverted"
        case .viridis: return "Viridis"
        case .magma: return "Magma"
        case .plasma: return "Plasma"
        }
    }

    /// 256-entry RGB look-up table, each component in `[0, 1]`.
    public func lut() -> [SIMD3<Float>] {
        (0..<256).map { i in
            let t = Float(i) / 255
            return sample(t)
        }
    }

    /// Continuous sampling of the map for `t ∈ [0, 1]`.
    public func sample(_ t: Float) -> SIMD3<Float> {
        let x = max(0, min(1, t))
        switch self {
        case .gray:
            return SIMD3(x, x, x)
        case .invertedGray:
            return SIMD3(1 - x, 1 - x, 1 - x)
        case .viridis:
            return clamp(viridis(x), 0, 1)
        case .magma:
            return clamp(magma(x), 0, 1)
        case .plasma:
            return clamp(plasma(x), 0, 1)
        }
    }

    // MARK: - Polynomial colour fits

    private func viridis(_ t: Float) -> SIMD3<Float> {
        let c0 = SIMD3<Float>(0.2777273272,  0.005407344544, 0.3340998832)
        let c1 = SIMD3<Float>(0.1050930431,  1.404613529,    1.384590162)
        let c2 = SIMD3<Float>(-0.3308618287, 0.214847176,    0.09509516862)
        let c3 = SIMD3<Float>(-4.634230030, -5.799100872,   -19.33244095)
        let c4 = SIMD3<Float>(6.228269936,   14.17993633,    56.69055260)
        let c5 = SIMD3<Float>(4.776384997,  -13.74514183,   -65.35303263)
        let c6 = SIMD3<Float>(-5.435455156,  4.645852474,    26.31218282)
        return horner(t, c0, c1, c2, c3, c4, c5, c6)
    }

    private func magma(_ t: Float) -> SIMD3<Float> {
        let c0 = SIMD3<Float>(-0.002136485053, -0.000749655152, -0.005386127855)
        let c1 = SIMD3<Float>(0.2516605407,    0.6775232436,    2.494026191)
        let c2 = SIMD3<Float>(8.353717238,    -3.577719586,    0.3144679030)
        let c3 = SIMD3<Float>(-27.66873308,    14.26473282,   -13.64921318)
        let c4 = SIMD3<Float>(52.17613308,   -27.94360443,    12.94416770)
        let c5 = SIMD3<Float>(-50.76852379,   29.04658287,    4.234001515)
        let c6 = SIMD3<Float>(18.65570506,   -11.48977351,   -5.601961508)
        return horner(t, c0, c1, c2, c3, c4, c5, c6)
    }

    private func plasma(_ t: Float) -> SIMD3<Float> {
        let c0 = SIMD3<Float>(0.05873234392,  0.02333670892,  0.5433401118)
        let c1 = SIMD3<Float>(2.176514634,    0.2383834171,   0.7539604341)
        let c2 = SIMD3<Float>(-2.689460976,  -7.455851110,    3.110799939)
        let c3 = SIMD3<Float>(6.130348345,    42.31123756,   -28.51885050)
        let c4 = SIMD3<Float>(-11.10743463,  -82.66631104,   60.13984767)
        let c5 = SIMD3<Float>(10.02306227,    71.41361370,  -54.07218351)
        let c6 = SIMD3<Float>(-3.658713842,  -22.93153897,   18.19190778)
        return horner(t, c0, c1, c2, c3, c4, c5, c6)
    }

    private func horner(_ t: Float, _ c0: SIMD3<Float>, _ c1: SIMD3<Float>,
                        _ c2: SIMD3<Float>, _ c3: SIMD3<Float>,
                        _ c4: SIMD3<Float>, _ c5: SIMD3<Float>,
                        _ c6: SIMD3<Float>) -> SIMD3<Float> {
        var acc = c6
        acc = c5 + t * acc
        acc = c4 + t * acc
        acc = c3 + t * acc
        acc = c2 + t * acc
        acc = c1 + t * acc
        acc = c0 + t * acc
        return acc
    }

    private func clamp(_ v: SIMD3<Float>, _ lo: Float, _ hi: Float) -> SIMD3<Float> {
        SIMD3(
            min(hi, max(lo, v.x)),
            min(hi, max(lo, v.y)),
            min(hi, max(lo, v.z))
        )
    }
}
