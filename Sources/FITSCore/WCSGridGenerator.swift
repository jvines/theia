import Foundation

public struct WCSGridline: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case ra, dec }
    public let kind: Kind
    /// The constant RA or Dec value in degrees that defines this line.
    public let value: Double
    /// Polyline points in 0-based image-pixel space.
    public let pixelPoints: [SIMD2<Double>]
}

public enum WCSGridGenerator {
    /// Picks a "nice" tick spacing (1/2/5 × 10ⁿ) that yields roughly `targetTicks` ticks
    /// over `range`.
    public static func niceTickSpacing(range: Double, targetTicks: Int) -> Double {
        guard range > 0, targetTicks > 0 else { return 1 }
        let rough = range / Double(targetTicks)
        let exp = floor(log10(rough))
        let frac = rough / pow(10, exp)
        let nice: Double
        if frac < 1.5 { nice = 1 }
        else if frac < 3.5 { nice = 2 }
        else if frac < 7.5 { nice = 5 }
        else { nice = 10 }
        return nice * pow(10, exp)
    }

    /// Generates RA and Dec gridlines covering the image extent. Each gridline is a
    /// polyline of image-pixel points sampled densely enough to look smooth when
    /// rendered. Returns empty array if the WCS cannot project the image corners.
    public static func gridlines(
        wcs: WCS,
        imageWidth: Int,
        imageHeight: Int,
        targetTicks: Int = 5,
        samples: Int = 64
    ) -> [WCSGridline] {
        let corners: [(Int, Int)] = [
            (0, 0), (imageWidth - 1, 0),
            (0, imageHeight - 1), (imageWidth - 1, imageHeight - 1),
        ]
        var ras: [Double] = []
        var decs: [Double] = []
        for (x, y) in corners {
            if let sky = wcs.pixelToSky(imageX: x, imageY: y) {
                ras.append(sky.ra)
                decs.append(sky.dec)
            }
        }
        guard let raMin = ras.min(), let raMax = ras.max(),
              let decMin = decs.min(), let decMax = decs.max() else {
            return []
        }

        let raSpacing = niceTickSpacing(range: raMax - raMin, targetTicks: targetTicks)
        let decSpacing = niceTickSpacing(range: decMax - decMin, targetTicks: targetTicks)

        var out: [WCSGridline] = []

        // RA lines (constant RA, varying Dec).
        let raStart = (raMin / raSpacing).rounded(.down) * raSpacing
        let raEnd = (raMax / raSpacing).rounded(.up) * raSpacing
        var ra = raStart
        while ra <= raEnd + 1e-12 {
            var pts: [SIMD2<Double>] = []
            for step in 0...samples {
                let dec = decMin + (decMax - decMin) * Double(step) / Double(samples)
                if let p = wcs.skyToPixel(ra: ra, dec: dec) {
                    pts.append(SIMD2(p.x, p.y))
                }
            }
            if pts.count >= 2 {
                out.append(WCSGridline(kind: .ra, value: ra, pixelPoints: pts))
            }
            ra += raSpacing
        }

        // Dec lines (constant Dec, varying RA).
        let decStart = (decMin / decSpacing).rounded(.down) * decSpacing
        let decEnd = (decMax / decSpacing).rounded(.up) * decSpacing
        var dec = decStart
        while dec <= decEnd + 1e-12 {
            var pts: [SIMD2<Double>] = []
            for step in 0...samples {
                let ra = raMin + (raMax - raMin) * Double(step) / Double(samples)
                if let p = wcs.skyToPixel(ra: ra, dec: dec) {
                    pts.append(SIMD2(p.x, p.y))
                }
            }
            if pts.count >= 2 {
                out.append(WCSGridline(kind: .dec, value: dec, pixelPoints: pts))
            }
            dec += decSpacing
        }

        return out
    }
}
