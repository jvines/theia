import Foundation

/// Celestial coordinate frames supported for cursor readout.
///
/// Transforms route through ICRS as the hub. Galactic and ecliptic use exact
/// rotation matrices. FK5(J2000) is treated as ICRS (the frame bias is ~23 mas,
/// below readout precision). FK4(B1950) uses the Murray (1989) rotation matrix
/// **with** the E-terms of aberration applied (removed going FK4→ICRS, added
/// back iteratively going ICRS→FK4), matching astropy to ~mas.
public enum CelestialFrame: String, Sendable, CaseIterable {
    case icrs
    case fk5
    case fk4
    case galactic
    case ecliptic

    /// Short label for the readout (DS9-style).
    public var label: String {
        switch self {
        case .icrs: return "ICRS"
        case .fk5: return "FK5"
        case .fk4: return "FK4"
        case .galactic: return "Galactic"
        case .ecliptic: return "Ecliptic"
        }
    }

    /// True for equatorial frames (longitude shown as RA hours, latitude as Dec).
    /// Galactic/ecliptic show both as degrees.
    public var isEquatorial: Bool {
        switch self {
        case .icrs, .fk5, .fk4: return true
        case .galactic, .ecliptic: return false
        }
    }
}

/// Converts spherical celestial coordinates between frames.
public enum CelestialTransform {
    /// Converts `(lon, lat)` in **degrees** from `source` to `target`.
    /// For equatorial frames lon/lat are RA/Dec; for galactic/ecliptic they are
    /// l/b or λ/β. Result longitude is wrapped to [0, 360).
    public static func convert(lon: Double, lat: Double,
                               from source: CelestialFrame,
                               to target: CelestialFrame) -> (lon: Double, lat: Double) {
        if source == target { return (normalize360(lon), lat) }
        let v = sphericalToUnit(lon: lon, lat: lat)
        let icrs = frameToICRS(v, source)
        let out = icrsToFrame(icrs, target)
        let (l, b) = unitToSpherical(out)
        return (normalize360(l), b)
    }

    // ICRS→Galactic matrix (NGP α=192.85948°, δ=27.12825°, l of NCP = 122.93192°),
    // as used by astropy's Galactic frame.
    private static let galacticFromICRS = Mat3(
        -0.054875560416215368, -0.873437090234885048, -0.483835015548713226,
         0.494109427875583673, -0.444829629960011178,  0.746982244497218890,
        -0.867666149019004701, -0.198076373431201525,  0.455983776175066340)

    // Rotation about the vernal-equinox (x) axis by the J2000 mean obliquity
    // ε = 23.4392911° (84381.448″, IAU 1976): ICRS→ecliptic.
    private static let eclipticFromICRS: Mat3 = {
        let eps = 23.4392911 * .pi / 180
        let c = cos(eps), s = sin(eps)
        return Mat3(1, 0, 0, 0, c, s, 0, -s, c)
    }()

    // Murray (1989) FK4NoETerms(B1950) → FK5(J2000) rotation matrix (maps B1950→J2000).
    private static let b1950ToJ2000 = Mat3(
        0.9999256794956877, -0.0111814832204662, -0.0048590038153592,
        0.0111814832391717,  0.9999374848933135, -0.0000271625947142,
        0.0048590037723143, -0.0000271702937440,  0.9999881946023742)

    // E-terms of aberration at B1950 (astropy `fk4_e_terms`, evaluated at B1950).
    private static let eTerms = (-1.6255741516894347e-06,
                                 -3.191905371563791e-07,
                                 -1.3842906719296592e-07)

    /// Frame unit vector → ICRS unit vector.
    private static func frameToICRS(_ v: (Double, Double, Double), _ frame: CelestialFrame) -> (Double, Double, Double) {
        switch frame {
        case .icrs, .fk5: return v
        case .galactic:   return matMulVec(transpose(galacticFromICRS), v)
        case .ecliptic:   return matMulVec(transpose(eclipticFromICRS), v)
        case .fk4:
            // FK4(with E-terms) → FK4NoETerms → FK5(≈ICRS).
            return matMulVec(b1950ToJ2000, removeETerms(v))
        }
    }

    /// ICRS unit vector → frame unit vector.
    private static func icrsToFrame(_ v: (Double, Double, Double), _ frame: CelestialFrame) -> (Double, Double, Double) {
        switch frame {
        case .icrs, .fk5: return v
        case .galactic:   return matMulVec(galacticFromICRS, v)
        case .ecliptic:   return matMulVec(eclipticFromICRS, v)
        case .fk4:
            // ICRS(≈FK5) → FK4NoETerms → FK4(with E-terms).
            return addETerms(matMulVec(transpose(b1950ToJ2000), v))
        }
    }

    /// Remove E-terms of aberration (FK4 with E-terms → FK4NoETerms):
    /// `r_noe = r − A + (A·r) r`. Direction only; magnitude is irrelevant downstream.
    private static func removeETerms(_ r: (Double, Double, Double)) -> (Double, Double, Double) {
        let a = eTerms
        let dot = a.0 * r.0 + a.1 * r.1 + a.2 * r.2
        return (r.0 - a.0 + dot * r.0, r.1 - a.1 + dot * r.1, r.2 - a.2 + dot * r.2)
    }

    /// Add E-terms back (FK4NoETerms → FK4), iterating `r = (A + r0)/(1 + A·r)`
    /// to convergence (astropy uses 10 iterations).
    private static func addETerms(_ r0: (Double, Double, Double)) -> (Double, Double, Double) {
        let a = eTerms
        var r = r0
        for _ in 0..<10 {
            let dot = a.0 * r.0 + a.1 * r.1 + a.2 * r.2
            let denom = 1 + dot
            r = ((a.0 + r0.0) / denom, (a.1 + r0.1) / denom, (a.2 + r0.2) / denom)
        }
        return r
    }

    // MARK: - Vector helpers

    private static func sphericalToUnit(lon: Double, lat: Double) -> (Double, Double, Double) {
        let l = lon * .pi / 180, b = lat * .pi / 180
        return (cos(b) * cos(l), cos(b) * sin(l), sin(b))
    }

    private static func unitToSpherical(_ v: (Double, Double, Double)) -> (Double, Double) {
        let lon = atan2(v.1, v.0) * 180 / .pi
        let lat = atan2(v.2, (v.0 * v.0 + v.1 * v.1).squareRoot()) * 180 / .pi
        return (lon, lat)
    }

    private static func normalize360(_ deg: Double) -> Double {
        let m = deg.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }
}

/// Minimal row-major 3×3 matrix for celestial rotations.
struct Mat3 {
    var m: (Double, Double, Double, Double, Double, Double, Double, Double, Double)

    init(_ a: Double, _ b: Double, _ c: Double,
         _ d: Double, _ e: Double, _ f: Double,
         _ g: Double, _ h: Double, _ i: Double) {
        m = (a, b, c, d, e, f, g, h, i)
    }
}

private func transpose(_ a: Mat3) -> Mat3 {
    Mat3(a.m.0, a.m.3, a.m.6,
         a.m.1, a.m.4, a.m.7,
         a.m.2, a.m.5, a.m.8)
}

private func matMulVec(_ a: Mat3, _ v: (Double, Double, Double)) -> (Double, Double, Double) {
    (a.m.0 * v.0 + a.m.1 * v.1 + a.m.2 * v.2,
     a.m.3 * v.0 + a.m.4 * v.1 + a.m.5 * v.2,
     a.m.6 * v.0 + a.m.7 * v.1 + a.m.8 * v.2)
}
