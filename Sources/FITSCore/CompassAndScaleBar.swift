import Foundation
import simd

public struct CompassDirections: Sendable, Equatable {
    /// Unit vector in image-pixel space that points along celestial east.
    public let eastDirectionImage: SIMD2<Double>
    /// Unit vector in image-pixel space that points along celestial north.
    public let northDirectionImage: SIMD2<Double>
}

public extension WCS {
    /// Local sky-orientation arrows in image space, derived from the inverse CD matrix.
    var compass: CompassDirections {
        // Inverse CD: maps (dRA, dDec) in degrees → (dx, dy) in image pixels.
        //   [dx]   1   [ cd22  -cd12] [dRA]
        //   [dy] = ─ × [-cd21   cd11] [dDec]
        //          det
        let det = cd11 * cd22 - cd12 * cd21
        // Direction in image for +1° RA (i.e. celestial east).
        let east = SIMD2(cd22, -cd21) / det
        // Direction in image for +1° Dec (i.e. celestial north).
        let north = SIMD2(-cd12, cd11) / det
        let eastUnit = east / max(simd_length(east), 1e-30)
        let northUnit = north / max(simd_length(north), 1e-30)
        return CompassDirections(eastDirectionImage: eastUnit, northDirectionImage: northUnit)
    }

    /// Approximate pixel scale in arcseconds per pixel (geometric mean of CD).
    var pixelScaleArcsec: Double {
        let degPerPix = (abs(cd11 * cd22 - cd12 * cd21)).squareRoot()
        return degPerPix * 3600
    }
}

public enum ScaleBar {
    /// Picks a round angular length close to `viewPointsTarget` view points wide,
    /// given the image pixel scale and the current viewport scale.
    public static func niceAngularExtent(
        viewPointsTarget: Double,
        pixelScaleArcsec: Double,
        viewportScale: Double
    ) -> (lengthArcsec: Double, lengthPoints: Double)? {
        guard pixelScaleArcsec > 0, viewportScale > 0 else { return nil }
        let arcsecRaw = viewPointsTarget * pixelScaleArcsec / viewportScale
        let arcsec = roundedNiceValue(arcsecRaw)
        let lengthPoints = arcsec * viewportScale / pixelScaleArcsec
        return (arcsec, lengthPoints)
    }

    /// Rounds `x` to the nearest 1, 2, or 5 × 10ⁿ.
    public static func roundedNiceValue(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        let exp = floor(log10(x))
        let frac = x / pow(10, exp)
        let nice: Double
        if frac < 1.5 { nice = 1 }
        else if frac < 3.5 { nice = 2 }
        else if frac < 7.5 { nice = 5 }
        else { nice = 10 }
        return nice * pow(10, exp)
    }
}
