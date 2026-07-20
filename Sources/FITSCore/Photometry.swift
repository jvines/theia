import Foundation
import simd

/// Aperture photometry on a `FITSImage` constrained to a `Region`.
/// Works for circle / box / ellipse / annulus / polygon in image frame; WCS-frame
/// regions need a `wcs` to project onto the image grid.
public struct PhotometryResult: Sendable, Equatable {
    /// Pixels falling inside the (inclusive) aperture, after NaN-skipping.
    public let pixelCount: Int
    /// Sum of physical values over the aperture (excluding NaN).
    public let sum: Double
    public let mean: Double
    public let median: Double
    public let stddev: Double
    public let min: Double
    public let max: Double
    /// Flux-weighted centroid in 0-based image pixel coords (NaN-skipping).
    public let centroid: (x: Double, y: Double)
    /// For annulus regions: median sky value across the annulus, or nil otherwise.
    public let sky: Double?
    /// `sum - sky * pixelCount` for annulus regions; nil otherwise.
    public let skySubtractedFlux: Double?
    /// Stddev of pixels in the sky annulus — useful for sky uncertainty propagation.
    public let skyStddev: Double?
    /// Number of pixels in the sky annulus.
    public let skyPixelCount: Int?
    /// PSF-fitted total flux (2π·A·σ²) when a Gaussian fit converged on this region.
    public let psfFlux: Double?
    /// PSF-fitted FWHM in pixels (matches the Gaussian fit's reported FWHM).
    public let psfFWHM: Double?

    /// Uncertainty on `sum` assuming Poisson noise (σ = √max(sum, 0)).
    public var sumError: Double { Foundation.sqrt(Swift.max(sum, 0)) }

    /// Uncertainty on `skySubtractedFlux`, propagating Poisson noise on the aperture
    /// plus sky-mean uncertainty across `skyPixelCount` measurements:
    ///   σ_net² = N + (N² × σ_sky² / N_sky)
    /// where N is aperture pixel count and σ_sky is sky stddev.
    public var skySubtractedFluxError: Double? {
        guard let sky = sky, let skyStd = skyStddev, let skyN = skyPixelCount, skyN > 0 else {
            return nil
        }
        _ = sky
        let n = Double(pixelCount)
        let nSky = Double(skyN)
        let aperturePoisson = Swift.max(sum, 0)         // raw σ² ≈ sum (Poisson)
        let skyMeanVar = (skyStd * skyStd) / nSky       // σ² of the sky mean
        let netVar = aperturePoisson + n * n * skyMeanVar
        return netVar.squareRoot()
    }

    public static func == (lhs: PhotometryResult, rhs: PhotometryResult) -> Bool {
        lhs.pixelCount == rhs.pixelCount &&
        lhs.sum == rhs.sum && lhs.mean == rhs.mean && lhs.median == rhs.median &&
        lhs.stddev == rhs.stddev && lhs.min == rhs.min && lhs.max == rhs.max &&
        lhs.centroid.x == rhs.centroid.x && lhs.centroid.y == rhs.centroid.y &&
        lhs.sky == rhs.sky && lhs.skySubtractedFlux == rhs.skySubtractedFlux &&
        lhs.skyStddev == rhs.skyStddev && lhs.skyPixelCount == rhs.skyPixelCount &&
        lhs.psfFlux == rhs.psfFlux && lhs.psfFWHM == rhs.psfFWHM
    }
}

public enum Photometry {
    /// Returns nil for unsupported (non-image / no-WCS) frames.
    public static func measure(region: Region, image: FITSImage, wcs: WCS?, psfFit: Bool = true) -> PhotometryResult? {
        guard var base = measureRaw(region: region, image: image, wcs: wcs) else { return nil }
        if psfFit, let centre = regionImageCentre(region: region, wcs: wcs) {
            let near = (Int(centre.x.rounded()), Int(centre.y.rounded()))
            if let fit = GaussianFit.fit(image: image, near: near, boxRadius: 8), fit.sigmaX > 0.5 {
                // Analytical Gaussian flux above the fitted baseline: 2π·A·σx·σy.
                let psf = 2 * .pi * fit.amplitude * fit.sigmaX * fit.sigmaY
                base = PhotometryResult(
                    pixelCount: base.pixelCount,
                    sum: base.sum, mean: base.mean, median: base.median, stddev: base.stddev,
                    min: base.min, max: base.max, centroid: base.centroid,
                    sky: base.sky, skySubtractedFlux: base.skySubtractedFlux,
                    skyStddev: base.skyStddev, skyPixelCount: base.skyPixelCount,
                    psfFlux: psf, psfFWHM: fit.fwhm
                )
            }
        }
        return base
    }

    private static func regionImageCentre(region: Region, wcs: WCS?) -> SIMD2<Double>? {
        switch region.shape {
        case .circle(let c, _),
             .box(let c, _, _, _),
             .ellipse(let c, _, _, _),
             .annulus(let c, _, _):
            return imageCenter(of: c, frame: region.frame, wcs: wcs)
        case .point(let p):
            return imageCenter(of: p, frame: region.frame, wcs: wcs)
        case .polygon:
            return nil
        }
    }

    private static func measureRaw(region: Region, image: FITSImage, wcs: WCS?) -> PhotometryResult? {
        switch region.shape {
        case .annulus(let center, let rIn, let rOut):
            guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let inPix = pixelLength(rIn, frame: region.frame, wcs: wcs),
                  let outPix = pixelLength(rOut, frame: region.frame, wcs: wcs) else { return nil }
            let bbox = clampBBox(cx: cp.x - outPix, cy: cp.y - outPix,
                                 w: 2 * outPix, h: 2 * outPix, image: image)
            return measureAnnulus(image: image, cx: cp.x, cy: cp.y, inner: inPix, outer: outPix, bbox: bbox)
        case .circle(let center, let radius):
            guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let rPix = pixelLength(radius, frame: region.frame, wcs: wcs) else { return nil }
            let bbox = clampBBox(cx: cp.x - rPix, cy: cp.y - rPix,
                                 w: 2 * rPix, h: 2 * rPix, image: image)
            return measureSampling(image: image, bbox: bbox) { x, y in
                let dx = Double(x) - cp.x, dy = Double(y) - cp.y
                return dx * dx + dy * dy <= rPix * rPix
            }
        case .box(let center, let w, let h, let angle):
            guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let wPix = pixelLength(w, frame: region.frame, wcs: wcs),
                  let hPix = pixelLength(h, frame: region.frame, wcs: wcs) else { return nil }
            let theta = angle * .pi / 180
            let cosT = Foundation.cos(theta), sinT = Foundation.sin(theta)
            let halfW = wPix / 2, halfH = hPix / 2
            let bbox = rotatedRectBBox(cx: cp.x, cy: cp.y, halfW: halfW, halfH: halfH, cosT: cosT, sinT: sinT, image: image)
            return measureSampling(image: image, bbox: bbox) { x, y in
                let dx = Double(x) - cp.x, dy = Double(y) - cp.y
                let lx =  dx * cosT + dy * sinT
                let ly = -dx * sinT + dy * cosT
                return abs(lx) <= halfW && abs(ly) <= halfH
            }
        case .ellipse(let center, let rx, let ry, let angle):
            guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let rxPix = pixelLength(rx, frame: region.frame, wcs: wcs),
                  let ryPix = pixelLength(ry, frame: region.frame, wcs: wcs),
                  rxPix > 0, ryPix > 0 else { return nil }
            let theta = angle * .pi / 180
            let cosT = Foundation.cos(theta), sinT = Foundation.sin(theta)
            let bbox = rotatedRectBBox(cx: cp.x, cy: cp.y, halfW: rxPix, halfH: ryPix, cosT: cosT, sinT: sinT, image: image)
            return measureSampling(image: image, bbox: bbox) { x, y in
                let dx = Double(x) - cp.x, dy = Double(y) - cp.y
                let lx =  dx * cosT + dy * sinT
                let ly = -dx * sinT + dy * cosT
                let nx = lx / rxPix, ny = ly / ryPix
                return nx * nx + ny * ny <= 1
            }
        case .polygon(let pts):
            guard region.frame == .image else { return nil }
            // vertices are 1-indexed in `.reg`; subtract 1 to match image-space.
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            for p in pts {
                minX = min(minX, p.x - 1); maxX = max(maxX, p.x - 1)
                minY = min(minY, p.y - 1); maxY = max(maxY, p.y - 1)
            }
            let bbox = clampBBox(cx: minX, cy: minY, w: maxX - minX, h: maxY - minY, image: image)
            return measureSampling(image: image, bbox: bbox) { x, y in
                Region.pointInPolygon(SIMD2(Double(x), Double(y)), vertices: pts)
            }
        case .point:
            return nil
        }
    }

    /// Axis-aligned bbox of a rotated rectangle of half-extents (halfW, halfH)
    /// around (cx, cy). For an ellipse this is also the axis-aligned bbox.
    private static func rotatedRectBBox(cx: Double, cy: Double, halfW: Double, halfH: Double, cosT: Double, sinT: Double, image: FITSImage) -> (Int, Int, Int, Int) {
        let extX = abs(cosT) * halfW + abs(sinT) * halfH
        let extY = abs(sinT) * halfW + abs(cosT) * halfH
        return clampBBox(cx: cx - extX, cy: cy - extY, w: 2 * extX, h: 2 * extY, image: image)
    }

    /// Clamp a real-valued box to integer pixel bounds inside the image extent.
    private static func clampBBox(cx: Double, cy: Double, w: Double, h: Double, image: FITSImage) -> (Int, Int, Int, Int) {
        let x0 = max(0, Int(floor(cx)))
        let y0 = max(0, Int(floor(cy)))
        let x1 = min(image.width - 1, Int(ceil(cx + w)))
        let y1 = min(image.height - 1, Int(ceil(cy + h)))
        return (x0, y0, x1, y1)
    }

    // MARK: - Internals

    private static func measureSampling(image: FITSImage, bbox: (Int, Int, Int, Int), contains: (Int, Int) -> Bool) -> PhotometryResult {
        var values: [Double] = []
        var sumXValue = 0.0, sumYValue = 0.0, weightSum = 0.0
        let (x0, y0, x1, y1) = bbox
        guard x0 <= x1, y0 <= y1 else {
            return reduce(values: values, centroidWeighted: (0, 0, 0),
                          sky: nil, sub: nil, skyStddev: nil, skyN: nil,
                          psfFlux: nil, psfFWHM: nil)
        }
        // Estimate a background from the pixels we touch (H6): a single pass
        // collects raw values, then we recompute the centroid using sky-
        // subtracted positive weights so a non-zero pedestal doesn't push the
        // result off the source.
        for y in y0...y1 {
            for x in x0...x1 where contains(x, y) {
                let v = image.physicalValue(x: x, y: y)
                if v.isNaN { continue }
                values.append(v)
            }
        }
        let bkg = backgroundEstimate(values)
        for y in y0...y1 {
            for x in x0...x1 where contains(x, y) {
                let v = image.physicalValue(x: x, y: y)
                if v.isNaN { continue }
                let weight = max(0, v - bkg)
                sumXValue += Double(x) * weight
                sumYValue += Double(y) * weight
                weightSum += weight
            }
        }
        return reduce(values: values, centroidWeighted: (sumXValue, sumYValue, weightSum),
                      sky: nil, sub: nil, skyStddev: nil, skyN: nil,
                      psfFlux: nil, psfFWHM: nil)
    }

    /// Median of NaN-skipped values; falls back to 0 if empty. Used as the
    /// background subtracted from centroid weights so pedestals / negative
    /// pixels don't distort the centre.
    private static func backgroundEstimate(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        sorted.sort()
        return sorted[sorted.count / 2]
    }

    private static func measureAnnulus(image: FITSImage, cx: Double, cy: Double, inner: Double, outer: Double, bbox: (Int, Int, Int, Int)) -> PhotometryResult {
        var values: [Double] = []
        var sumXValue = 0.0, sumYValue = 0.0, weightSum = 0.0
        let (x0, y0, x1, y1) = bbox
        guard x0 <= x1, y0 <= y1 else {
            return reduce(values: values, centroidWeighted: (0, 0, 0),
                          sky: 0, sub: 0, skyStddev: 0, skyN: 0, psfFlux: nil, psfFWHM: nil)
        }
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let d2 = dx * dx + dy * dy
                if d2 < inner * inner || d2 > outer * outer { continue }
                let v = image.physicalValue(x: x, y: y)
                if v.isNaN { continue }
                values.append(v)
                sumXValue += Double(x) * v
                sumYValue += Double(y) * v
                weightSum += v
            }
        }
        var sortedValues = values
        sortedValues.sort()
        let sky = sortedValues.isEmpty ? 0 : sortedValues[sortedValues.count / 2]
        let subtracted = values.reduce(0, +) - sky * Double(values.count)
        // Sky stddev (sample, NaN-skipped — already filtered above).
        let skyMean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let skyVar = values.count <= 1 ? 0 : values.reduce(0) { $0 + ($1 - skyMean) * ($1 - skyMean) } / Double(values.count - 1)
        let skyStd = skyVar.squareRoot()
        return reduce(values: values, centroidWeighted: (sumXValue, sumYValue, weightSum),
                      sky: sky, sub: subtracted, skyStddev: skyStd, skyN: values.count,
                      psfFlux: nil, psfFWHM: nil)
    }

    private static func reduce(values: [Double], centroidWeighted: (Double, Double, Double),
                               sky: Double?, sub: Double?, skyStddev: Double?, skyN: Int?,
                               psfFlux: Double?, psfFWHM: Double?) -> PhotometryResult {
        let n = values.count
        let sum = values.reduce(0, +)
        let mean = n == 0 ? 0 : sum / Double(n)
        var sorted = values
        sorted.sort()
        let median: Double
        if sorted.isEmpty { median = 0 }
        else if sorted.count % 2 == 1 { median = sorted[sorted.count / 2] }
        else { median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 }
        let variance = n <= 1 ? 0 : values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
        let std = variance.squareRoot()
        let lo = sorted.first ?? 0
        let hi = sorted.last ?? 0
        let (sx, sy, ws) = centroidWeighted
        let cx = abs(ws) > 0 ? sx / ws : 0
        let cy = abs(ws) > 0 ? sy / ws : 0
        return PhotometryResult(
            pixelCount: n, sum: sum, mean: mean, median: median, stddev: std,
            min: lo, max: hi, centroid: (cx, cy),
            sky: sky, skySubtractedFlux: sub,
            skyStddev: skyStddev, skyPixelCount: skyN,
            psfFlux: psfFlux, psfFWHM: psfFWHM
        )
    }
}

