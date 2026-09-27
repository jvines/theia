import Foundation
import FITSCore

public struct MeasurementResult: Sendable, Equatable {
    public let pixelDistance: Double
    public let skyDistanceArcsec: Double?
    public let positionAngleDeg: Double?

    public var lines: [String] {
        var result = [String(format: "Pixel distance: %.2f px", pixelDistance)]
        if let arcsec = skyDistanceArcsec, let angle = positionAngleDeg {
            if arcsec < 60 {
                result.append(String(format: "Sky distance: %.3f″", arcsec))
            } else if arcsec < 3600 {
                result.append(String(format: "Sky distance: %.3f′ (%.2f″)", arcsec / 60, arcsec))
            } else {
                result.append(String(format: "Sky distance: %.4f° (%.2f′)", arcsec / 3600, arcsec / 60))
            }
            result.append(String(format: "Position angle: %.2f° (E of N)", angle))
        }
        return result
    }
}

public enum Measurements {
    /// Angular measurements use the exact sub-pixel endpoints on the displayed WCS.
    public static func between(from: SIMD2<Double>, to: SIMD2<Double>,
                               wcs: WCS?) -> MeasurementResult {
        let delta = to - from
        let pixelDistance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard let wcs,
              let start = wcs.pixelToSky(imageX: from.x, imageY: from.y),
              let end = wcs.pixelToSky(imageX: to.x, imageY: to.y) else {
            return MeasurementResult(pixelDistance: pixelDistance,
                                     skyDistanceArcsec: nil, positionAngleDeg: nil)
        }
        let arcsec = CatalogQuery.angularDistance(
            ra1: start.ra, dec1: start.dec, ra2: end.ra, dec2: end.dec
        ) * 3600
        let ra1 = start.ra * .pi / 180, dec1 = start.dec * .pi / 180
        let ra2 = end.ra * .pi / 180, dec2 = end.dec * .pi / 180
        let dRA = ra2 - ra1
        let y = sin(dRA) * cos(dec2)
        let x = cos(dec1) * sin(dec2) - sin(dec1) * cos(dec2) * cos(dRA)
        var positionAngle = atan2(y, x) * 180 / .pi
        if positionAngle < 0 { positionAngle += 360 }
        return MeasurementResult(pixelDistance: pixelDistance,
                                 skyDistanceArcsec: arcsec,
                                 positionAngleDeg: positionAngle)
    }
}
