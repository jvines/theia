import Foundation

/// 1D extractors over a `FITSImage` for diagnostic plots.
public enum Profiles {
    public enum Interpolation: Sendable {
        case nearest
        case bilinear
    }

    public struct LineSample: Sendable, Equatable {
        public let distance: Double  // pixels from line start
        public let imageX: Double
        public let imageY: Double
        public let value: Double     // NaN if outside the image
    }

    public struct RadialBin: Sendable, Equatable {
        public let radius: Double    // bin centre (pixels)
        public let count: Int
        public let sum: Double
        public let mean: Double
        public let median: Double
        public let stddev: Double
    }

    public struct GrowthPoint: Sendable, Equatable {
        public let radius: Double           // aperture radius
        public let cumulativeFlux: Double   // sum of all pixels within radius
        public let cumulativeCount: Int
    }

    /// Sample `samples` equally-spaced points from `from` to `to` (0-based image
    /// coordinates). `interpolation` defaults to nearest-neighbour; bilinear gives a
    /// smoother profile for off-axis lines at the cost of slight value averaging.
    /// Out-of-bounds points are NaN.
    public static func lineProfile(image: FITSImage, from: (Double, Double), to: (Double, Double),
                                   samples: Int, interpolation: Interpolation = .nearest) -> [LineSample] {
        precondition(samples >= 2, "need at least 2 samples")
        var out: [LineSample] = []
        out.reserveCapacity(samples)
        let dx = to.0 - from.0, dy = to.1 - from.1
        let total = (dx * dx + dy * dy).squareRoot()
        for i in 0..<samples {
            let t = Double(i) / Double(samples - 1)
            let px = from.0 + t * dx
            let py = from.1 + t * dy
            let v = sampleValue(image: image, x: px, y: py, interpolation: interpolation)
            out.append(LineSample(distance: t * total, imageX: px, imageY: py, value: v))
        }
        return out
    }

    /// Pixel sampler used by all 1D / 2D extractors. Bilinear handles NaN by
    /// renormalising weights over the non-NaN corners.
    public static func sampleValue(image: FITSImage, x: Double, y: Double,
                                   interpolation: Interpolation = .nearest) -> Double {
        switch interpolation {
        case .nearest:
            let ix = Int(x.rounded()), iy = Int(y.rounded())
            if ix < 0 || ix >= image.width || iy < 0 || iy >= image.height { return .nan }
            return image.physicalValue(x: ix, y: iy)
        case .bilinear:
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let x1 = x0 + 1, y1 = y0 + 1
            // Reject samples that have NO valid corner.
            if x1 < 0 || x0 >= image.width || y1 < 0 || y0 >= image.height { return .nan }
            let fx = x - Double(x0), fy = y - Double(y0)
            // Pull each corner (NaN if outside).
            func corner(_ xi: Int, _ yi: Int) -> Double {
                if xi < 0 || xi >= image.width || yi < 0 || yi >= image.height { return .nan }
                return image.physicalValue(x: xi, y: yi)
            }
            let v00 = corner(x0, y0), v10 = corner(x1, y0)
            let v01 = corner(x0, y1), v11 = corner(x1, y1)
            // Bilinear weights, NaN-skipping.
            let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
            let w01 = (1 - fx) * fy,       w11 = fx * fy
            var num = 0.0, den = 0.0
            for (v, w) in [(v00, w00), (v10, w10), (v01, w01), (v11, w11)] where !v.isNaN {
                num += v * w; den += w
            }
            return den > 0 ? num / den : .nan
        }
    }

    /// Azimuthally-averaged profile of `image` centred at `center` (0-based image
    /// pixels). Bins are `[k*binWidth, (k+1)*binWidth)`; the returned `radius` is
    /// the bin centre. NaN pixels are skipped.
    public static func radialProfile(image: FITSImage, center: (Double, Double), maxRadius: Double, binWidth: Double) -> [RadialBin] {
        precondition(binWidth > 0, "binWidth must be > 0")
        let nBins = Int((maxRadius / binWidth).rounded(.up))
        var buckets = [[Double]](repeating: [], count: nBins)
        let cx = center.0, cy = center.1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let v = image.physicalValue(x: x, y: y)
                if v.isNaN { continue }
                let r = ((Double(x) - cx).squared + (Double(y) - cy).squared).squareRoot()
                if r >= maxRadius { continue }
                let bin = Int(r / binWidth)
                buckets[bin].append(v)
            }
        }
        return buckets.enumerated().compactMap { idx, values in
            guard !values.isEmpty else { return nil }
            let r = (Double(idx) + 0.5) * binWidth
            let sum = values.reduce(0, +)
            let mean = sum / Double(values.count)
            var sorted = values; sorted.sort()
            let median: Double
            if sorted.count % 2 == 1 { median = sorted[sorted.count / 2] }
            else { median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 }
            let variance = values.count <= 1 ? 0 : values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
            return RadialBin(radius: r, count: values.count, sum: sum, mean: mean,
                             median: median, stddev: variance.squareRoot())
        }
    }

    /// Aperture growth curve: cumulative flux inside a circle of radius r, swept from
    /// r=`step` to r=`maxRadius`. The curve plateaus at the radius where most of the
    /// source flux is collected — the natural aperture-correction radius.
    public static func growthCurve(image: FITSImage, center: (Double, Double),
                                   maxRadius: Double, step: Double) -> [GrowthPoint] {
        precondition(step > 0, "step must be > 0")
        let cx = center.0, cy = center.1
        // Pre-compute distances for every pixel in a bounding box and bin them.
        let bound = Int(maxRadius.rounded(.up))
        let xLo = max(0, Int(cx) - bound), xHi = min(image.width - 1, Int(cx) + bound)
        let yLo = max(0, Int(cy) - bound), yHi = min(image.height - 1, Int(cy) + bound)
        var sortedByRadius: [(Double, Double)] = []
        sortedByRadius.reserveCapacity((xHi - xLo + 1) * (yHi - yLo + 1))
        for y in yLo...yHi {
            for x in xLo...xHi {
                let v = image.physicalValue(x: x, y: y)
                if v.isNaN { continue }
                let dx = Double(x) - cx, dy = Double(y) - cy
                let r = (dx * dx + dy * dy).squareRoot()
                if r > maxRadius { continue }
                sortedByRadius.append((r, v))
            }
        }
        sortedByRadius.sort { $0.0 < $1.0 }
        var out: [GrowthPoint] = []
        var cumulative = 0.0
        var cumulativeCount = 0
        var pixelIdx = 0
        var r = step
        while r <= maxRadius + 1e-12 {
            while pixelIdx < sortedByRadius.count && sortedByRadius[pixelIdx].0 <= r {
                cumulative += sortedByRadius[pixelIdx].1
                cumulativeCount += 1
                pixelIdx += 1
            }
            out.append(GrowthPoint(radius: r, cumulativeFlux: cumulative, cumulativeCount: cumulativeCount))
            r += step
        }
        return out
    }

    /// For an NAXIS=3 cube HDU, returns the value at pixel `(x, y)` across every plane.
    /// Useful for spectral cubes (value vs wavelength / channel).
    public static func cubeSpectrum(hdu: FITSHDU, atPixel pixel: (Int, Int)) throws -> [Double] {
        guard hdu.naxis == 3 else { throw FITSError.invalidHeader("cubeSpectrum requires NAXIS=3") }
        let depth = hdu.axes[2]
        var out = [Double]()
        out.reserveCapacity(depth)
        for p in 0..<depth {
            let img = try FITSImage(hdu: hdu, plane: p)
            out.append(img.physicalValue(x: pixel.0, y: pixel.1))
        }
        return out
    }

    /// Integrate a region's pixels at every plane → spectrum. Each entry is the
    /// `combine` (default `.sum`) of all pixels inside the region for that plane.
    /// NaN pixels are skipped. `mean` is robust against outliers; `sum` gives total flux.
    public enum CubeCombine: Sendable { case sum, mean, median }

    public static func cubeSpectrum(hdu: FITSHDU, region: Region, wcs: WCS?, combine: CubeCombine = .sum) throws -> [Double] {
        guard hdu.naxis == 3 else { throw FITSError.invalidHeader("cubeSpectrum requires NAXIS=3") }
        let depth = hdu.axes[2]
        var out = [Double]()
        out.reserveCapacity(depth)
        for p in 0..<depth {
            let img = try FITSImage(hdu: hdu, plane: p)
            guard let r = Photometry.measure(region: region, image: img, wcs: wcs) else {
                out.append(.nan); continue
            }
            switch combine {
            case .sum:    out.append(r.sum)
            case .mean:   out.append(r.mean)
            case .median: out.append(r.median)
            }
        }
        return out
    }

    /// Position-velocity diagram: for a line in the spatial plane through a cube,
    /// extract a 2D image with horizontal axis = position along the line (`samples`
    /// points) and vertical axis = plane index. Returns a float32 `FITSImage`
    /// suitable for stretching/colormapping like any other image.
    public static func pvDiagram(hdu: FITSHDU, from: (Double, Double), to: (Double, Double),
                                 samples: Int, interpolation: Interpolation = .bilinear) throws -> FITSImage {
        guard hdu.naxis == 3 else { throw FITSError.invalidHeader("pvDiagram requires NAXIS=3") }
        let depth = hdu.axes[2]
        var pix = [Float](repeating: 0, count: samples * depth)
        let dx = to.0 - from.0, dy = to.1 - from.1
        for p in 0..<depth {
            let img = try FITSImage(hdu: hdu, plane: p)
            for i in 0..<samples {
                let t = Double(i) / Double(samples - 1)
                let px = from.0 + t * dx
                let py = from.1 + t * dy
                pix[p * samples + i] = Float(sampleValue(image: img, x: px, y: py, interpolation: interpolation))
            }
        }
        return .fromFloat32(pixels: pix, width: samples, height: depth)
    }
}

private extension Double {
    var squared: Double { self * self }
}
