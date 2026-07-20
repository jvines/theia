import XCTest
@testable import FITSCore

/// Reference values cross-checked against astropy's SkyCoord transforms.
final class CelestialFrameTests: XCTestCase {

    private func assertClose(_ got: (lon: Double, lat: Double),
                             _ lon: Double, _ lat: Double,
                             tol: Double, _ msg: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        // Compare on the sphere via angular separation to avoid lon wrap / cos(lat) issues.
        let d = angularSeparation(got.lon, got.lat, lon, lat)
        XCTAssertLessThan(d, tol, "\(msg): got (\(got.lon), \(got.lat)) expected (\(lon), \(lat)), sep=\(d * 3600)\"",
                          file: file, line: line)
    }

    // MARK: - Galactic (exact)

    func testGalacticCenterToICRS() {
        // l=0, b=0 → ICRS RA=266.40499°, Dec=-28.93617°
        let r = CelestialTransform.convert(lon: 0, lat: 0, from: .galactic, to: .icrs)
        assertClose(r, 266.40499, -28.93617, tol: 1.0 / 3600, "galactic center")
    }

    func testNorthGalacticPoleToICRS() {
        // b=+90 → ICRS RA=192.85948°, Dec=+27.12825°
        let r = CelestialTransform.convert(lon: 123, lat: 90, from: .galactic, to: .icrs)
        assertClose(r, 192.85948, 27.12825, tol: 1.0 / 3600, "NGP")
    }

    func testVegaICRSToGalactic() {
        // Vega ICRS (279.234735, 38.783689) → galactic ≈ (67.4488, 19.2373).
        // Tolerance is set by the 4-decimal rounding of this literature value
        // (~1–2″); the exact IAU points above pin the matrix to <1″.
        let r = CelestialTransform.convert(lon: 279.234735, lat: 38.783689, from: .icrs, to: .galactic)
        assertClose(r, 67.4488, 19.2373, tol: 5.0 / 3600, "Vega galactic")
    }

    func testGalacticRoundTrip() {
        let r = CelestialTransform.convert(lon: 133.7, lat: -8.2, from: .icrs, to: .galactic)
        let back = CelestialTransform.convert(lon: r.lon, lat: r.lat, from: .galactic, to: .icrs)
        assertClose(back, 133.7, -8.2, tol: 1e-6, "galactic round trip")
    }

    // MARK: - Ecliptic (exact)

    func testNorthCelestialPoleToEcliptic() {
        // ICRS Dec=+90 → ecliptic β = 90−ε = 66.5607°, λ=90°
        let r = CelestialTransform.convert(lon: 0, lat: 90, from: .icrs, to: .ecliptic)
        assertClose(r, 90.0, 66.5607089, tol: 2.0 / 3600, "NCP→ecliptic")
    }

    func testVernalEquinoxToEcliptic() {
        let r = CelestialTransform.convert(lon: 0, lat: 0, from: .icrs, to: .ecliptic)
        assertClose(r, 0, 0, tol: 1.0 / 3600, "vernal equinox")
    }

    func testEclipticPointToICRS() {
        // ecliptic (λ=90, β=0) → ICRS (RA=90, Dec=+ε=23.4393°)
        let r = CelestialTransform.convert(lon: 90, lat: 0, from: .ecliptic, to: .icrs)
        assertClose(r, 90.0, 23.4392911, tol: 1.0 / 3600, "ecliptic→ICRS")
    }

    // MARK: - FK4 (rigorous, with E-terms; reference values from astropy 7.0.1)

    func testFK4ToICRSOrigin() {
        // FK4 B1950 (0,0) → ICRS (0.6406846126, 0.2784069697)
        let r = CelestialTransform.convert(lon: 0, lat: 0, from: .fk4, to: .icrs)
        assertClose(r, 0.6406846126, 0.2784069697, tol: 0.1 / 3600, "FK4→ICRS (0,0)")
    }

    func testFK4ToICRSMidSky() {
        // FK4 B1950 (180,30) → ICRS (180.6397521691, 29.7216543867)
        let r = CelestialTransform.convert(lon: 180, lat: 30, from: .fk4, to: .icrs)
        assertClose(r, 180.6397521691, 29.7216543867, tol: 0.1 / 3600, "FK4→ICRS (180,30)")
    }

    func testICRSToFK4Origin() {
        // ICRS (0,0) → FK4 B1950 (359.3593143215, -0.2784073623)
        let r = CelestialTransform.convert(lon: 0, lat: 0, from: .icrs, to: .fk4)
        assertClose(r, 359.3593143215, -0.2784073623, tol: 0.1 / 3600, "ICRS→FK4 (0,0)")
    }

    func testFK4RoundTrip() {
        let r = CelestialTransform.convert(lon: 200.0, lat: -15.0, from: .icrs, to: .fk4)
        let back = CelestialTransform.convert(lon: r.lon, lat: r.lat, from: .fk4, to: .icrs)
        assertClose(back, 200.0, -15.0, tol: 0.01 / 3600, "FK4 round trip")
    }

    // MARK: - FK5 ≈ ICRS

    func testFK5IsICRSToReadoutPrecision() {
        let r = CelestialTransform.convert(lon: 150.0, lat: 22.0, from: .fk5, to: .icrs)
        assertClose(r, 150.0, 22.0, tol: 0.1 / 3600, "FK5≈ICRS")
    }
}

/// Angular separation in degrees between two (lon, lat) points (haversine).
private func angularSeparation(_ lon1: Double, _ lat1: Double, _ lon2: Double, _ lat2: Double) -> Double {
    let d2r = Double.pi / 180
    let φ1 = lat1 * d2r, φ2 = lat2 * d2r
    let dφ = (lat2 - lat1) * d2r, dλ = (lon2 - lon1) * d2r
    let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
    return 2 * asin(min(1, a.squareRoot())) / d2r
}
