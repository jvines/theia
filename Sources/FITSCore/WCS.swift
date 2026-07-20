import Foundation

/// Minimal World Coordinate System for a 2D FITS image. Only the TAN (gnomonic)
/// projection is supported in v1 — this covers almost all CCD imaging in astronomy.
public struct WCS: Sendable {
    /// 1-based FITS reference pixel.
    public let crpix: (x: Double, y: Double)
    /// Reference value in degrees (RA, Dec).
    public let crval: (ra: Double, dec: Double)
    /// CD matrix in degrees per pixel.
    public let cd11: Double
    public let cd12: Double
    public let cd21: Double
    public let cd22: Double
    /// Projection code from CTYPE (e.g. "TAN").
    public let projectionType: String
    /// SIP forward distortion (A_*, B_*) coefficients, if present.
    public let sipForward: SIPPolynomial?
    /// SIP inverse (AP_*, BP_*) coefficients, if present.
    public let sipInverse: SIPPolynomial?

    /// Sparse representation of a SIP polynomial pair. `a[i][j]` and `b[i][j]`
    /// hold the coefficient for `dx^i * dy^j` (zero outside).
    public struct SIPPolynomial: Sendable, Equatable {
        public let order: Int
        public let a: [[Double]]   // [order+1][order+1]
        public let b: [[Double]]   // [order+1][order+1]

        public func apply(dx: Double, dy: Double) -> (du: Double, dv: Double) {
            var du = 0.0, dv = 0.0
            for i in 0...order {
                for j in 0...(order - i) {
                    if i == 0 && j == 0 { continue }
                    let term = pow(dx, Double(i)) * pow(dy, Double(j))
                    du += a[i][j] * term
                    dv += b[i][j] * term
                }
            }
            return (du, dv)
        }
    }

    /// Optional `WCSNAME` value (free-form description, e.g. "ICRS").
    public let name: String?

    /// The celestial frame the projected `(ra, dec)` from `pixelToSky` are in,
    /// inferred from CTYPE (RA-/GLON/ELON), RADESYS, and EQUINOX.
    public let nativeFrame: CelestialFrame

    /// Variant suffix (`""`, `"A"`, `"B"`, …). Default is the primary `""` WCS.
    public let variant: String

    /// All variants present in the header (including primary as `""`).
    public static func availableVariants(in header: FITSHeader) -> [String] {
        var out: Set<String> = []
        // Primary if CTYPE1 (no suffix) exists.
        if header["CTYPE1"] != nil { out.insert("") }
        // A through Z.
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            if header["CTYPE1\(ch)"] != nil { out.insert(String(ch)) }
        }
        return Array(out).sorted()
    }

    public init?(header: FITSHeader, variant: String = "") {
        self.variant = variant
        self.name = header["WCSNAME\(variant)"]?.stringValue
        guard
            let ctype1 = header["CTYPE1\(variant)"]?.stringValue,
            let ctype2 = header["CTYPE2\(variant)"]?.stringValue
        else { return nil }
        // CTYPE format is `<AXIS>--<PROJ>[-SIP]` with variable dashes padding to 8 chars
        // (12 with SIP). Detect projection by substring search.
        let combined = ctype1 + " " + ctype2
        let knownProjections = ["TAN", "SIN", "ZEA", "STG", "CAR", "MER", "AIT", "MOL"]
        guard let proj = knownProjections.first(where: { combined.contains($0) }) else { return nil }
        // Both CTYPEs should reference the same projection.
        guard ctype1.contains(proj), ctype2.contains(proj) else { return nil }
        self.projectionType = proj
        self.nativeFrame = Self.inferFrame(ctype1: ctype1, header: header, variant: variant)
        let hasSIP = combined.contains("SIP")
        self.sipForward = hasSIP ? Self.parseSIP(header: header, prefixA: "A", prefixB: "B", orderKey: "A_ORDER") : nil
        self.sipInverse = hasSIP ? Self.parseSIP(header: header, prefixA: "AP", prefixB: "BP", orderKey: "AP_ORDER") : nil

        guard
            let crpix1 = header["CRPIX1\(variant)"]?.doubleValue,
            let crpix2 = header["CRPIX2\(variant)"]?.doubleValue,
            let crval1 = header["CRVAL1\(variant)"]?.doubleValue,
            let crval2 = header["CRVAL2\(variant)"]?.doubleValue
        else { return nil }
        self.crpix = (crpix1, crpix2)
        self.crval = (crval1, crval2)

        if let a = header["CD1_1\(variant)"]?.doubleValue,
           let b = header["CD1_2\(variant)"]?.doubleValue,
           let c = header["CD2_1\(variant)"]?.doubleValue,
           let d = header["CD2_2\(variant)"]?.doubleValue {
            self.cd11 = a; self.cd12 = b; self.cd21 = c; self.cd22 = d
        } else if let cdelt1 = header["CDELT1\(variant)"]?.doubleValue,
                  let cdelt2 = header["CDELT2\(variant)"]?.doubleValue {
            let rho = (header["CROTA2\(variant)"]?.doubleValue ?? 0) * .pi / 180
            let cosR = cos(rho), sinR = sin(rho)
            self.cd11 =  cdelt1 * cosR
            self.cd12 = -cdelt2 * sinR
            self.cd21 =  cdelt1 * sinR
            self.cd22 =  cdelt2 * cosR
        } else {
            return nil
        }
    }

    /// Infers the celestial frame from the longitude CTYPE prefix and, for
    /// equatorial axes, RADESYS / EQUINOX. Defaults to ICRS.
    private static func inferFrame(ctype1: String, header: FITSHeader, variant: String) -> CelestialFrame {
        let prefix = ctype1.uppercased()
        if prefix.hasPrefix("GLON") { return .galactic }
        if prefix.hasPrefix("ELON") { return .ecliptic }
        // Equatorial (RA--/…): prefer RADESYS, fall back to EQUINOX.
        if let radesys = header["RADESYS\(variant)"]?.stringValue?.uppercased()
            ?? header["RADECSYS"]?.stringValue?.uppercased() {
            if radesys.contains("FK4") { return .fk4 }
            if radesys.contains("FK5") { return .fk5 }
            if radesys.contains("ICRS") { return .icrs }
        }
        if let equinox = header["EQUINOX\(variant)"]?.doubleValue ?? header["EPOCH"]?.doubleValue {
            return equinox < 1984 ? .fk4 : .fk5   // Besselian cutoff
        }
        return .icrs
    }

    /// Maps a 0-based image (x, y) to sky (RA, Dec) in degrees. Returns nil on math failure.
    public func pixelToSky(imageX x: Int, imageY y: Int) -> (ra: Double, dec: Double)? {
        // FITS pixel coords are 1-based.
        let dx0 = Double(x) + 1 - crpix.x
        let dy0 = Double(y) + 1 - crpix.y
        var dx = dx0, dy = dy0
        if let sip = sipForward {
            let (du, dv) = sip.apply(dx: dx0, dy: dy0)
            dx = dx0 + du
            dy = dy0 + dv
        }
        let xiDeg = cd11 * dx + cd12 * dy
        let etaDeg = cd21 * dx + cd22 * dy

        // Cylindrical projections: (xi, eta) are coordinates in the projection plane
        // measured from CRVAL, in degrees. Treat separately from the zenithal family.
        if projectionType == "CAR" {
            return (normalizeRA(crval.ra + xiDeg), crval.dec + etaDeg)
        }
        if projectionType == "MER" {
            // eta encodes the native latitude θ via the Gudermannian; like the other
            // cylindricals the sky dec is measured from the reference dec (CRVAL2).
            let etaRad = etaDeg * .pi / 180
            let thetaDeg = (2 * atan(exp(etaRad)) - .pi / 2) * 180 / .pi
            return (normalizeRA(crval.ra + xiDeg), crval.dec + thetaDeg)
        }
        if projectionType == "AIT" {
            // FITS WCS Paper II Hammer-Aitoff. (xi, eta) in deg → projection plane in rad,
            // then Wikipedia's standard inverse Hammer formulas.
            let xRad = xiDeg * .pi / 180
            let yRad = etaDeg * .pi / 180
            let Z2 = 1 - (xRad / 4) * (xRad / 4) - (yRad / 2) * (yRad / 2)
            guard Z2 > 0 else { return nil }
            let Z = Z2.squareRoot()
            let denom = 2 * Z * Z - 1
            guard abs(denom) > 1e-30 else { return nil }
            let phi = 2 * atan((Z * xRad) / (2 * denom))
            let theta = asin(yRad * Z)
            return offsetFromNative(phi: phi, theta: theta)
        }
        if projectionType == "MOL" {
            // FITS WCS Paper II Mollweide. (xi, eta) in deg → native (φ, θ) in rad.
            let xRad = xiDeg * .pi / 180
            let yRad = etaDeg * .pi / 180
            let s = yRad / Foundation.sqrt(2.0)
            guard abs(s) <= 1 else { return nil }
            let gamma = asin(s)
            let sinDec = (2 * gamma + sin(2 * gamma)) / .pi
            guard abs(sinDec) <= 1 else { return nil }
            let theta = asin(sinDec)
            let cosG = cos(gamma)
            guard abs(cosG) > 1e-12 else { return offsetFromNative(phi: 0, theta: theta) }
            let phi = (.pi * xRad) / (2 * Foundation.sqrt(2.0) * cosG)
            return offsetFromNative(phi: phi, theta: theta)
        }
        let xi = xiDeg * .pi / 180
        let eta = etaDeg * .pi / 180
        let rho = (xi * xi + eta * eta).squareRoot()

        let ra0 = crval.ra * .pi / 180
        let dec0 = crval.dec * .pi / 180

        let ra: Double
        let dec: Double
        if rho == 0 {
            ra = ra0
            dec = dec0
        } else {
            guard let c = nativeColatitude(rho: rho) else { return nil }
            let cosC = cos(c), sinC = sin(c)
            dec = asin(cosC * sin(dec0) + eta * sinC * cos(dec0) / rho)
            ra = ra0 + atan2(xi * sinC, rho * cos(dec0) * cosC - eta * sin(dec0) * sinC)
        }
        return (normalizeRA(ra * 180 / .pi), dec * 180 / .pi)
    }

    /// Native colatitude (angle from the projection pole) for the given radial
    /// distance `rho` (in radians) under the active projection. Returns nil if
    /// `rho` is outside the projection's domain.
    private func nativeColatitude(rho: Double) -> Double? {
        switch projectionType {
        case "TAN": return atan(rho)
        case "STG": return 2 * atan(rho / 2)            // stereographic
        case "SIN": return rho <= 1 ? asin(rho) : nil
        case "ZEA": return rho <= 2 ? 2 * asin(rho / 2) : nil
        default: return nil
        }
    }

    /// Maps a sky (RA, Dec) in degrees back to 0-based image (x, y). Returns nil if
    /// the point lies outside the projection's valid domain.
    ///
    /// This is the inverse of `pixelToSky` using the direct tangent-plane form
    /// (consistent with the forward path), with denominator chosen per projection:
    ///   TAN: denom = cos(c)
    ///   SIN: denom = 1
    ///   ZEA: denom = cos(c/2)
    public func skyToPixel(ra: Double, dec: Double) -> (x: Double, y: Double)? {
        // Cylindrical / pseudo-cylindrical projections.
        if ["CAR", "MER", "AIT", "MOL"].contains(projectionType) {
            var dRA = ra - crval.ra
            while dRA > 180  { dRA -= 360 }
            while dRA < -180 { dRA += 360 }
            let phi = dRA * .pi / 180
            let theta = (dec - crval.dec) * .pi / 180
            let xiDeg: Double
            let etaDeg: Double
            switch projectionType {
            case "CAR":
                xiDeg = dRA
                etaDeg = dec - crval.dec
            case "MER":
                // Native latitude θ relative to the reference declination (CRVAL2).
                let theta = (dec - crval.dec) * .pi / 180
                guard cos(theta) > 0 else { return nil }
                xiDeg = dRA
                etaDeg = log(tan(.pi / 4 + theta / 2)) * 180 / .pi
            case "AIT":
                // FITS Paper II eq 80-83. x_rad = 2 cos θ sin(φ/2) / Z, y_rad = sin θ / Z
                // with Z = √((1 + cos θ cos(φ/2)) / 2).
                let cosT = cos(theta), sinT = sin(theta)
                let arg = (1 + cosT * cos(phi / 2)) / 2
                guard arg > 0 else { return nil }
                let Z = arg.squareRoot()
                guard Z > 1e-12 else { return nil }
                let xRad = 2 * cosT * sin(phi / 2) / Z
                let yRad = sinT / Z
                xiDeg = xRad * 180 / .pi
                etaDeg = yRad * 180 / .pi
            case "MOL":
                // Solve 2γ + sin(2γ) = π sin θ for γ via Newton iteration.
                // Near the poles |sin θ|→1, |fp|→0 and Newton can overshoot;
                // short-circuit to the closed-form γ=±π/2 and bail out if the
                // iteration somehow fails to converge.
                let sinT = sin(theta)
                var gamma: Double
                if abs(sinT) > 0.9999 {
                    gamma = sinT > 0 ? .pi / 2 : -.pi / 2
                } else {
                    let target = .pi * sinT
                    gamma = theta
                    var converged = false
                    for _ in 0..<64 {
                        let f = 2 * gamma + sin(2 * gamma) - target
                        let fp = 2 + 2 * cos(2 * gamma)
                        if abs(fp) < 1e-30 { break }
                        let delta = f / fp
                        gamma -= delta
                        if abs(delta) < 1e-12 { converged = true; break }
                    }
                    if !converged { return nil }
                }
                let xRad = (2 * Foundation.sqrt(2.0) / .pi) * phi * cos(gamma)
                let yRad = Foundation.sqrt(2.0) * sin(gamma)
                xiDeg = xRad * 180 / .pi
                etaDeg = yRad * 180 / .pi
            default:
                return nil
            }
            let det = cd11 * cd22 - cd12 * cd21
            guard abs(det) > 1e-30 else { return nil }
            var dx = (cd22 * xiDeg - cd12 * etaDeg) / det
            var dy = (-cd21 * xiDeg + cd11 * etaDeg) / det
            if let sip = sipInverse {
                let (du, dv) = sip.apply(dx: dx, dy: dy)
                dx += du; dy += dv
            } else if let fwd = sipForward {
                let (du, dv) = inverseSIPCorrection(fwd, U: dx, V: dy)
                dx += du; dy += dv
            }
            return (dx + crpix.x - 1, dy + crpix.y - 1)
        }

        let raR = ra * .pi / 180
        let decR = dec * .pi / 180
        let ra0 = crval.ra * .pi / 180
        let dec0 = crval.dec * .pi / 180
        let dRA = raR - ra0

        // Angular distance c from (CRVAL_ra, CRVAL_dec) to (ra, dec).
        // Use atan2 form for stability near c ≈ 0.
        let sinCa = cos(decR) * sin(dRA)
        let sinCb = cos(dec0) * sin(decR) - sin(dec0) * cos(decR) * cos(dRA)
        let sinC = (sinCa * sinCa + sinCb * sinCb).squareRoot()
        let cosC = sin(decR) * sin(dec0) + cos(decR) * cos(dec0) * cos(dRA)
        let c = atan2(sinC, cosC)

        let denom: Double
        switch projectionType {
        case "TAN":
            guard cosC > 0 else { return nil }   // c < π/2
            denom = cosC
        case "SIN":
            guard cosC >= 0 else { return nil }  // c ≤ π/2
            denom = 1.0
        case "ZEA":
            denom = cos(c / 2)                   // > 0 for c < π
        case "STG":
            denom = (1 + cosC) / 2               // R = 2 tan(c/2) → divisor (1+cos c)/2
        default:
            return nil
        }

        let xiRad = cos(decR) * sin(dRA) / denom
        let etaRad = (sin(decR) * cos(dec0) - cos(decR) * sin(dec0) * cos(dRA)) / denom

        let xiDeg = xiRad * 180 / .pi
        let etaDeg = etaRad * 180 / .pi

        let det = cd11 * cd22 - cd12 * cd21
        guard abs(det) > 1e-30 else { return nil }
        var dx = (cd22 * xiDeg - cd12 * etaDeg) / det
        var dy = (-cd21 * xiDeg + cd11 * etaDeg) / det

        if let sip = sipInverse {
            let (du, dv) = sip.apply(dx: dx, dy: dy)
            dx += du
            dy += dv
        } else if let fwd = sipForward {
            let (du, dv) = inverseSIPCorrection(fwd, U: dx, V: dy)
            dx += du
            dy += dv
        }

        return (dx + crpix.x - 1, dy + crpix.y - 1)
    }

    /// Wrap RA to [0, 360).
    private func normalizeRA(_ ra: Double) -> Double {
        let r = ra.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// For cylindrical / pseudo-cylindrical projections, `(φ, θ)` in radians at the
    /// native pole is `(0, 0)`. The sky position is just CRVAL + (φ, θ) in degrees,
    /// modulo the standard RA wrap.
    private func offsetFromNative(phi: Double, theta: Double) -> (ra: Double, dec: Double) {
        let raDeg = crval.ra + phi * 180 / .pi
        let decDeg = crval.dec + theta * 180 / .pi
        return (normalizeRA(raDeg), decDeg)
    }

    /// Numerically invert the forward SIP distortion when the header omits the
    /// optional AP/BP inverse coefficients. Given the distortion-corrected
    /// intermediate pixel offsets `(U, V)` (i.e. CD⁻¹·world), recover the raw
    /// offsets `(u, v)` satisfying `u + A(u,v) = U` and `v + B(u,v) = V` by
    /// fixed-point iteration — it contracts quickly because SIP distortions are
    /// small. Returns the correction `(u − U, v − V)`, matching the AP/BP path's
    /// `dx += du` application shape, so `skyToPixel` inverts `pixelToSky`.
    private func inverseSIPCorrection(_ sip: SIPPolynomial, U: Double, V: Double) -> (du: Double, dv: Double) {
        var u = U, v = V
        for _ in 0..<50 {
            let (au, bv) = sip.apply(dx: u, dy: v)
            let un = U - au
            let vn = V - bv
            let converged = abs(un - u) < 1e-10 && abs(vn - v) < 1e-10
            u = un; v = vn
            if converged { break }
        }
        return (u - U, v - V)
    }

    private static func parseSIP(header: FITSHeader, prefixA: String, prefixB: String, orderKey: String) -> SIPPolynomial? {
        guard let order = header[orderKey]?.intValue, order >= 1 else { return nil }
        var a = Array(repeating: Array(repeating: 0.0, count: order + 1), count: order + 1)
        var b = Array(repeating: Array(repeating: 0.0, count: order + 1), count: order + 1)
        var any = false
        for i in 0...order {
            for j in 0...(order - i) {
                if let v = header["\(prefixA)_\(i)_\(j)"]?.doubleValue { a[i][j] = v; any = true }
                if let v = header["\(prefixB)_\(i)_\(j)"]?.doubleValue { b[i][j] = v; any = true }
            }
        }
        return any ? SIPPolynomial(order: order, a: a, b: b) : nil
    }
}
