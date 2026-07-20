import Foundation
import simd

/// Display colour maps for stretched pixel values in `[0, 1]`.
///
/// The perceptual maps (viridis, magma, plasma) are our own degree-10 least-squares
/// polynomial fits to matplotlib's listed colormaps, which their authors dedicated
/// to the public domain (CC0). Max error vs the reference data is < 1% per channel —
/// ample for an 8-bit display LUT.
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
    //
    // Degree-10 least-squares fits to matplotlib's public-domain (CC0)
    // viridis/magma/plasma data; `c[k]` is the coefficient of `t^k`.

    private func viridis(_ t: Float) -> SIMD3<Float> {
        horner(t, [
            SIMD3<Float>(0.26879913, 0.0024819165, 0.32894473),
            SIMD3<Float>(0.19569507, 1.6241486, 1.6020904),
            SIMD3<Float>(2.0691932, -3.5256532, -3.7756279),
            SIMD3<Float>(-32.744093, 20.025165, 19.950264),
            SIMD3<Float>(32.005827, -76.074043, -186.39315),
            SIMD3<Float>(641.82133, 153.34602, 836.4229),
            SIMD3<Float>(-3124.5776, -134.14808, -1969.5555),
            SIMD3<Float>(6561.9629, -27.623013, 2614.46),
            SIMD3<Float>(-7221.6573, 154.33954, -1948.3737),
            SIMD3<Float>(4071.0459, -117.42885, 739.12616),
            SIMD3<Float>(-929.40272, 30.368758, -103.64169),
        ])
    }

    private func magma(_ t: Float) -> SIMD3<Float> {
        horner(t, [
            SIMD3<Float>(0.00040627635, 0.0069230209, 0.0062637587),
            SIMD3<Float>(0.27655803, -0.92762505, 2.6406562),
            SIMD3<Float>(6.0660788, 45.254936, -32.540586),
            SIMD3<Float>(-15.785758, -529.56166, 548.12481),
            SIMD3<Float>(141.79465, 2976.8216, -3997.3018),
            SIMD3<Float>(-1010.5285, -9380.0634, 15336.155),
            SIMD3<Float>(3470.9812, 17758.798, -34548.072),
            SIMD3<Float>(-6369.3282, -20613.712, 47349.901),
            SIMD3<Float>(6464.3613, 14347.74, -38851.355),
            SIMD3<Float>(-3433.5881, -5488.7219, 17553.826),
            SIMD3<Float>(746.73879, 885.35553, -3360.6363),
        ])
    }

    private func plasma(_ t: Float) -> SIMD3<Float> {
        horner(t, [
            SIMD3<Float>(0.053096878, 0.03452846, 0.52562476),
            SIMD3<Float>(2.8995847, -1.0860295, 1.6466476),
            SIMD3<Float>(-15.314252, 28.695096, -17.514267),
            SIMD3<Float>(98.207169, -350.31654, 175.24254),
            SIMD3<Float>(-374.72283, 2110.7324, -1036.2597),
            SIMD3<Float>(878.07156, -7032.4501, 3531.4365),
            SIMD3<Float>(-1325.2747, 14102.556, -7471.2468),
            SIMD3<Float>(1301.7653, -17529.002, 10078.322),
            SIMD3<Float>(-806.75145, 13256.988, -8461.6295),
            SIMD3<Float>(285.83751, -5599.3137, 4029.2021),
            SIMD3<Float>(-43.832226, 1014.1378, -829.5845),
        ])
    }

    /// Horner evaluation of a polynomial with vector coefficients. `c[0]` is the
    /// constant term, `c[k]` the coefficient of `t^k`.
    private func horner(_ t: Float, _ c: [SIMD3<Float>]) -> SIMD3<Float> {
        guard var acc = c.last else { return .zero }
        for k in stride(from: c.count - 2, through: 0, by: -1) {
            acc = c[k] + t * acc
        }
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
