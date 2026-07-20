import Foundation

/// Pure-logic helpers for building astronomy catalog queries from an image WCS.
public enum CatalogQuery {
    /// Haversine great-circle angular distance in degrees.
    public static func angularDistance(
        ra1: Double, dec1: Double, ra2: Double, dec2: Double
    ) -> Double {
        let ra1R = ra1 * .pi / 180
        let dec1R = dec1 * .pi / 180
        let ra2R = ra2 * .pi / 180
        let dec2R = dec2 * .pi / 180
        let dRA = ra2R - ra1R
        let dDec = dec2R - dec1R
        let h = sin(dDec / 2) * sin(dDec / 2)
              + cos(dec1R) * cos(dec2R) * sin(dRA / 2) * sin(dRA / 2)
        return 2 * atan2(h.squareRoot(), (1 - h).squareRoot()) * 180 / .pi
    }

    /// Image WCS + dimensions → centre (deg) + bounding-circle radius (deg) suitable
    /// for a TAP cone search.
    public static func coneSearch(
        wcs: WCS,
        imageWidth: Int,
        imageHeight: Int
    ) -> (centerRA: Double, centerDec: Double, radiusDeg: Double)? {
        let cx = imageWidth / 2
        let cy = imageHeight / 2
        guard let centre = wcs.pixelToSky(imageX: cx, imageY: cy) else { return nil }
        let corners: [(Int, Int)] = [
            (0, 0), (imageWidth - 1, 0),
            (0, imageHeight - 1), (imageWidth - 1, imageHeight - 1),
        ]
        var maxDist = 0.0
        for (x, y) in corners {
            guard let p = wcs.pixelToSky(imageX: x, imageY: y) else { continue }
            let d = angularDistance(ra1: centre.ra, dec1: centre.dec, ra2: p.ra, dec2: p.dec)
            if d > maxDist { maxDist = d }
        }
        return (centre.ra, centre.dec, maxDist)
    }

    /// Builds an ADQL query for a Gaia DR3 cone search on the ESA Gaia archive TAP.
    public static func gaiaConeSearchADQL(
        centerRA: Double,
        centerDec: Double,
        radiusDeg: Double,
        limit: Int = 1000
    ) -> String {
        """
        SELECT TOP \(limit) ra, dec, phot_g_mean_mag \
        FROM gaiadr3.gaia_source \
        WHERE 1=CONTAINS(POINT('ICRS', ra, dec), \
        CIRCLE('ICRS', \(centerRA), \(centerDec), \(radiusDeg)))
        """
    }
}
