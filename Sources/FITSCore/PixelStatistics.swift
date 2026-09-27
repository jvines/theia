import Foundation

public struct Histogram: Sendable, Equatable {
    public let counts: [Int]
    public let edges: [Double]

    /// Cumulative distribution function, normalized so the last entry is 1.0
    /// (unless all counts are zero, in which case all entries are 0).
    public func cdf() -> [Double] {
        let total = counts.reduce(0, +)
        if total == 0 { return [Double](repeating: 0, count: counts.count) }
        var out = [Double](repeating: 0, count: counts.count)
        var running = 0
        for i in counts.indices {
            running += counts[i]
            out[i] = Double(running) / Double(total)
        }
        return out
    }

    /// Histogram-equalization mapping: returns the CDF value at the bin containing `value`.
    /// Values outside the histogram range clamp to 0 / 1. NaN propagates.
    public func equalize(_ value: Double) -> Double {
        if value.isNaN { return .nan }
        guard let lo = edges.first, let hi = edges.last, hi > lo else { return 0 }
        if value <= lo { return 0 }
        if value >= hi { return cdf().last ?? 1 }
        let width = (hi - lo) / Double(counts.count)
        var idx = Int((value - lo) / width)
        if idx >= counts.count { idx = counts.count - 1 }
        return cdf()[idx]
    }
}

public enum PixelStatistics {
    /// Returns the minimum and maximum of `values`, skipping NaN. Returns nil if all values are NaN.
    public static func minMax(_ values: [Double]) -> (min: Double, max: Double)? {
        var lo = Double.infinity
        var hi = -Double.infinity
        var seen = false
        for v in values where !v.isNaN {
            if v < lo { lo = v }
            if v > hi { hi = v }
            seen = true
        }
        return seen ? (lo, hi) : nil
    }

    /// IRAF zscale algorithm (Davis 1986). Returns a (z1, z2) range that gives
    /// good contrast for typical astronomical images by fitting a sigma-clipped line
    /// through sorted pixel values.
    ///
    /// - parameters:
    ///   - values: pixel values (NaN entries are ignored).
    ///   - contrast: lower values produce a wider range; IRAF default is 0.25.
    ///   - nSamples: target number of pixels to sample from the image.
    public static func zscale(
        _ values: [Double],
        contrast: Double = 0.25,
        nSamples: Int = 600,
        maxIters: Int = 5,
        rejectionSigma: Double = 2.5
    ) -> (z1: Double, z2: Double)? {
        zscaleSampled(
            pixelCount: values.count, contrast: contrast, nSamples: nSamples,
            maxIters: maxIters, rejectionSigma: rejectionSigma
        ) { values[$0] }
    }

    /// Run zscale by reading at most `nSamples` source pixels. The caller can
    /// provide a memory-mapped image without materializing its full pixel array.
    public static func zscaleSampled(
        pixelCount: Int,
        contrast: Double = 0.25,
        nSamples: Int = 600,
        maxIters: Int = 5,
        rejectionSigma: Double = 2.5,
        sampleAt: (Int) -> Double
    ) -> (z1: Double, z2: Double)? {
        guard pixelCount > 0, nSamples > 0 else { return nil }
        // Stride-sample NaN-free pixels so the sample spans the input.
        var sample = [Double]()
        sample.reserveCapacity(min(nSamples, pixelCount))
        let nPix = pixelCount
        let stride = max(1, Int((Double(nPix) / Double(nSamples)).rounded(.up)))
        var i = 0
        while i < nPix && sample.count < nSamples {
            let v = sampleAt(i)
            if v.isFinite { sample.append(v) }
            i += stride
        }
        guard !sample.isEmpty else { return nil }
        sample.sort()
        let n = sample.count
        let zmin = sample[0]
        let zmax = sample[n - 1]
        if n < 5 || contrast <= 0 { return (zmin, zmax) }

        let centerIdx = n / 2
        let centerVal = sample[centerIdx]

        // Iterative sigma-clipped linear regression on (pixel index, sorted value).
        let xs = (0..<n).map(Double.init)
        var mask = [Bool](repeating: true, count: n)
        var slope = 0.0
        for _ in 0..<maxIters {
            let (s, b) = leastSquares(x: xs, y: sample, mask: mask)
            slope = s
            var residuals = [Double](repeating: 0, count: n)
            var used = [Double]()
            used.reserveCapacity(n)
            for j in 0..<n where mask[j] {
                residuals[j] = sample[j] - (b + s * xs[j])
                used.append(residuals[j])
            }
            let sigma = standardDeviation(used)
            if sigma == 0 { break }
            let threshold = rejectionSigma * sigma
            var rejected = 0
            for j in 0..<n where mask[j] {
                if abs(residuals[j]) > threshold {
                    mask[j] = false
                    rejected += 1
                }
            }
            if rejected == 0 { break }
        }

        let slopePerPix = slope / contrast
        let z1 = max(zmin, centerVal - slopePerPix * Double(centerIdx))
        let z2 = min(zmax, centerVal + slopePerPix * Double(n - 1 - centerIdx))
        return (z1, z2)
    }

    private static func leastSquares(x: [Double], y: [Double], mask: [Bool]) -> (slope: Double, intercept: Double) {
        var n = 0
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for i in x.indices where mask[i] {
            sx += x[i]; sy += y[i]; sxx += x[i] * x[i]; sxy += x[i] * y[i]
            n += 1
        }
        guard n > 1 else { return (0, n == 1 ? sy : 0) }
        let dn = Double(n)
        let meanX = sx / dn
        let meanY = sy / dn
        let den = sxx - dn * meanX * meanX
        if abs(den) < 1e-30 { return (0, meanY) }
        let slope = (sxy - dn * meanX * meanY) / den
        let intercept = meanY - slope * meanX
        return (slope, intercept)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let ss = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (ss / Double(values.count)).squareRoot()
    }

    public struct SigmaClipped: Equatable, Sendable {
        public let mean: Double
        public let stddev: Double
        public let count: Int
    }

    /// Sigma-clipped mean/stddev over `values`. Iteratively drops samples outside
    /// `mean ± sigma·σ` until either convergence or `iterations`. Returns nil-equivalent
    /// stats with count=0 when all values are NaN — see `sigmaClippedOptional`.
    public static func sigmaClipped(_ values: [Double], sigma: Double = 3, iterations: Int = 5) -> SigmaClipped {
        sigmaClippedOptional(values, sigma: sigma, iterations: iterations) ?? SigmaClipped(mean: 0, stddev: 0, count: 0)
    }

    public static func sigmaClippedOptional(_ values: [Double], sigma: Double, iterations: Int) -> SigmaClipped? {
        var keep = values.filter { !$0.isNaN }
        guard !keep.isEmpty else { return nil }
        for _ in 0..<iterations {
            let mean = keep.reduce(0, +) / Double(keep.count)
            let varSum = keep.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            let std = (varSum / Double(Swift.max(keep.count - 1, 1))).squareRoot()
            let lo = mean - sigma * std, hi = mean + sigma * std
            let filtered = keep.filter { $0 >= lo && $0 <= hi }
            if filtered.count == keep.count { break }
            if filtered.count < 5 { break }
            keep = filtered
        }
        let mean = keep.reduce(0, +) / Double(keep.count)
        let varSum = keep.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let std = (varSum / Double(Swift.max(keep.count - 1, 1))).squareRoot()
        return SigmaClipped(mean: mean, stddev: std, count: keep.count)
    }

    /// Returns the (lower, upper) percentile values of `values` as a (vmin, vmax) pair
    /// suitable for stretch clipping. NaN is skipped.
    ///
    /// - parameters:
    ///   - values: pixel values; NaN entries are ignored.
    ///   - lower: lower percentile (0–100). Out-of-range values are clamped.
    ///   - upper: upper percentile (0–100). Out-of-range values are clamped.
    ///
    /// If `lower > upper` the bounds are swapped so the returned vmin ≤ vmax invariant
    /// always holds. Linear interpolation between adjacent ranks is used.
    public static func percentiles(_ values: [Double], lower: Double, upper: Double) -> (vmin: Double, vmax: Double)? {
        var lo = max(0.0, min(100.0, lower))
        var hi = max(0.0, min(100.0, upper))
        if lo > hi { swap(&lo, &hi) }
        var clean = values.filter { !$0.isNaN }
        guard !clean.isEmpty else { return nil }
        clean.sort()
        return (interpolatedPercentile(sorted: clean, p: lo),
                interpolatedPercentile(sorted: clean, p: hi))
    }

    /// Linear interpolation between sorted ranks (NumPy "linear" / type 7).
    private static func interpolatedPercentile(sorted s: [Double], p: Double) -> Double {
        if s.count == 1 { return s[0] }
        let rank = (p / 100.0) * Double(s.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return s[lo] }
        let frac = rank - Double(lo)
        return s[lo] * (1 - frac) + s[hi] * frac
    }

    /// Computes a histogram of `values` over `range` with `bins` equal-width bins.
    /// Edges are `[lo, lo+w, ..., hi]` (length = bins+1). Bin k holds values in
    /// `[edges[k], edges[k+1])`, except the last bin which also includes `hi`. NaN is skipped.
    public static func histogram(_ values: [Double], bins: Int, range: ClosedRange<Double>) -> Histogram {
        precondition(bins > 0, "bins must be positive")
        let lo = range.lowerBound
        let hi = range.upperBound
        let width = (hi - lo) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        guard width.isFinite, width > 0 else {
            return Histogram(counts: counts, edges: [Double](repeating: lo, count: bins + 1))
        }
        for v in values where v.isFinite {
            if v < lo || v > hi { continue }
            var idx = Int((v - lo) / width)
            if idx >= bins { idx = bins - 1 }  // rounded hi falls into the last bin
            counts[idx] += 1
        }
        var edges = [Double](repeating: 0, count: bins + 1)
        for i in 0...bins { edges[i] = lo + Double(i) * width }
        return Histogram(counts: counts, edges: edges)
    }
}
