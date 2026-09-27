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
        (try? radialProfileCheckingCancellation(image: image, center: center,
                                                maxRadius: maxRadius, binWidth: binWidth,
                                                checkCancellation: {})) ?? []
    }

    /// Cancellable variant used by analysis jobs. Cancellation is checked during
    /// image traversal and while reducing the occupied radial bins.
    public static func radialProfileCheckingCancellation(
        image: FITSImage, center: (Double, Double), maxRadius: Double, binWidth: Double,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [RadialBin] {
        precondition(binWidth > 0, "binWidth must be > 0")
        guard maxRadius.isFinite, maxRadius > 0,
              center.0.isFinite, center.1.isFinite else { return [] }
        // Store only occupied bins. A dragged radius may be much larger than
        // the image, so allocating maxRadius/binWidth empty buckets is unsafe.
        var buckets: [Int: [Double]] = [:]
        let cx = center.0, cy = center.1
        for y in 0..<image.height {
            try checkCancellation()
            for x in 0..<image.width {
                if x & 8_191 == 0 { try checkCancellation() }
                let v = image.physicalValue(x: x, y: y)
                if v.isNaN { continue }
                let r = ((Double(x) - cx).squared + (Double(y) - cy).squared).squareRoot()
                if r >= maxRadius { continue }
                let scaled = r / binWidth
                guard scaled.isFinite, scaled < Double(Int.max) else { continue }
                buckets[Int(scaled), default: []].append(v)
            }
        }
        var result: [RadialBin] = []
        for idx in buckets.keys.sorted() {
            try checkCancellation()
            guard let values = buckets[idx], !values.isEmpty else { continue }
            let r = (Double(idx) + 0.5) * binWidth
            var sum = 0.0
            for (index, value) in values.enumerated() {
                if index & 8_191 == 0 { try checkCancellation() }
                sum += value
            }
            let mean = sum / Double(values.count)
            let median = try medianCheckingCancellation(values, checkCancellation: checkCancellation)
            var varianceSum = 0.0
            for (index, value) in values.enumerated() {
                if index & 8_191 == 0 { try checkCancellation() }
                varianceSum += (value - mean) * (value - mean)
            }
            let variance = values.count <= 1 ? 0 : varianceSum / Double(values.count - 1)
            result.append(RadialBin(radius: r, count: values.count, sum: sum, mean: mean,
                                    median: median, stddev: variance.squareRoot()))
        }
        return result
    }

    private static func medianCheckingCancellation(
        _ input: [Double], checkCancellation: () throws -> Void
    ) throws -> Double {
        var values = input
        func select(_ rank: Int) throws -> Double {
            var left = 0, right = values.count - 1
            while left <= right {
                try checkCancellation()
                let middle = left + (right - left) / 2
                let pivot = [values[left], values[middle], values[right]].sorted()[1]
                var lower = left, cursor = left, upper = right
                var visited = 0
                while cursor <= upper {
                    if visited & 8_191 == 0 { try checkCancellation() }
                    visited += 1
                    if values[cursor] < pivot {
                        values.swapAt(lower, cursor)
                        lower += 1
                        cursor += 1
                    } else if values[cursor] > pivot {
                        values.swapAt(cursor, upper)
                        upper -= 1
                    } else {
                        cursor += 1
                    }
                }
                if rank < lower { right = lower - 1 }
                else if rank > upper { left = upper + 1 }
                else { return values[rank] }
            }
            preconditionFailure("median rank was not found")
        }
        let upper = try select(values.count / 2)
        guard values.count.isMultiple(of: 2) else { return upper }
        let lower = try select(values.count / 2 - 1)
        return (lower + upper) / 2
    }

    /// Aperture growth curve: cumulative flux inside a circle of radius r, swept from
    /// r=`step` to r=`maxRadius`. The curve plateaus at the radius where most of the
    /// source flux is collected — the natural aperture-correction radius.
    public static func growthCurve(image: FITSImage, center: (Double, Double),
                                   maxRadius: Double, step: Double) -> [GrowthPoint] {
        (try? growthCurveCheckingCancellation(image: image, center: center,
                                              maxRadius: maxRadius, step: step,
                                              checkCancellation: {})) ?? []
    }

    /// Cancellable variant used by the growth-curve analysis job.
    public static func growthCurveCheckingCancellation(
        image: FITSImage, center: (Double, Double), maxRadius: Double, step: Double,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [GrowthPoint] {
        precondition(step > 0, "step must be > 0")
        guard maxRadius.isFinite, maxRadius > 0,
              center.0.isFinite, center.1.isFinite else { return [] }
        let cx = center.0, cy = center.1
        // Each bin represents the first plotted aperture that includes a pixel.
        // This avoids sorting every pixel by distance and lets cancellation stop
        // the scan promptly when the controls change.
        var radii: [Double] = []
        var radius = step
        while radius <= maxRadius + 1e-12 {
            if radii.count & 8_191 == 0 { try checkCancellation() }
            radii.append(radius)
            let next = radius + step
            guard next > radius else { break }
            radius = next
        }
        guard !radii.isEmpty else { return [] }
        var binFlux = [Double](repeating: 0, count: radii.count)
        var binCount = [Int](repeating: 0, count: radii.count)
        let xLo = Int(max(0, min(Double(image.width), (cx - maxRadius).rounded(.down))))
        let xHi = Int(max(-1, min(Double(image.width - 1), (cx + maxRadius).rounded(.up))))
        let yLo = Int(max(0, min(Double(image.height), (cy - maxRadius).rounded(.down))))
        let yHi = Int(max(-1, min(Double(image.height - 1), (cy + maxRadius).rounded(.up))))
        if xLo <= xHi, yLo <= yHi {
            for y in yLo...yHi {
                try checkCancellation()
                for x in xLo...xHi {
                    if x & 8_191 == 0 { try checkCancellation() }
                    let v = image.physicalValue(x: x, y: y)
                    if v.isNaN { continue }
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance > maxRadius { continue }
                    var low = 0, high = radii.count
                    while low < high {
                        let middle = low + (high - low) / 2
                        if radii[middle] < distance { low = middle + 1 }
                        else { high = middle }
                    }
                    if low < radii.count {
                        binFlux[low] += v
                        binCount[low] += 1
                    }
                }
            }
        }
        var out: [GrowthPoint] = []
        var cumulative = 0.0
        var cumulativeCount = 0
        out.reserveCapacity(radii.count)
        for index in radii.indices {
            if index & 8_191 == 0 { try checkCancellation() }
            cumulative += binFlux[index]
            cumulativeCount += binCount[index]
            out.append(GrowthPoint(radius: radii[index], cumulativeFlux: cumulative,
                                   cumulativeCount: cumulativeCount))
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
