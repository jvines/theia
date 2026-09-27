import Foundation

/// Lightweight source detection — find local maxima above an absolute threshold,
/// then refine each to a 3×3 centroid for sub-pixel position.
///
/// Not a full DAOFIND / SExtractor pipeline (no kernel correlation, no PSF model),
/// but adequate for picking targets, dropping point regions, sanity-checking field
/// detection thresholds, and seeding aperture photometry.
public enum SourceExtractor {
    public struct Source: Sendable, Equatable {
        public let x: Double   // 0-based image pixel
        public let y: Double
        public let peak: Double
    }

    /// Detect sources above either a fixed `threshold` (if non-nil) or a local
    /// background-derived threshold (if nil). Local threshold uses a sliding box
    /// of `backgroundBoxSize` pixels: candidate qualifies when its value exceeds
    /// `localMedian + nSigma * localMAD * 1.4826` (MAD → σ approximation).
    /// Robust against gradients and large bright sources.
    public static func detect(image: FITSImage,
                              threshold: Double? = nil,
                              minSeparation: Int = 3,
                              backgroundBoxSize: Int = 21,
                              nSigma: Double = 5) -> [Source] {
        (try? detectCheckingCancellation(
            image: image, threshold: threshold, minSeparation: minSeparation,
            backgroundBoxSize: backgroundBoxSize, nSigma: nSigma,
            checkCancellation: {}
        )) ?? []
    }

    /// Job-friendly detector. Checks cancellation through the image scan, local
    /// background calculation, candidate sort and separation pass.
    public static func detectCheckingCancellation(
        image: FITSImage,
        threshold: Double? = nil,
        minSeparation: Int = 3,
        backgroundBoxSize: Int = 21,
        nSigma: Double = 5,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [Source] {
        let w = image.width, h = image.height
        guard w >= 3, h >= 3 else { return [] }
        let half = max(0, backgroundBoxSize / 2)
        // 1) Identify all local maxima (8-neighbour) above threshold (global or local).
        var candidates: [Source] = []
        for y in 1..<(h - 1) {
            try checkCancellation()
            for x in 1..<(w - 1) {
                if x & 63 == 0 { try checkCancellation() }
                let v = image.physicalValue(x: x, y: y)
                if v.isNaN { continue }
                let cutoff: Double
                if let t = threshold {
                    cutoff = t
                } else {
                    cutoff = try localCutoff(image: image, x: x, y: y,
                                             half: half, nSigma: nSigma,
                                             checkCancellation: checkCancellation)
                }
                if v <= cutoff { continue }
                var isPeak = true
                outer: for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nv = image.physicalValue(x: x + dx, y: y + dy)
                        if nv.isNaN { continue }
                        if nv > v { isPeak = false; break outer }
                    }
                }
                if isPeak {
                    candidates.append(Source(x: Double(x), y: Double(y), peak: v))
                }
            }
        }
        // 2) Sort by peak desc, greedily accept candidates separated by minSeparation.
        try sortByPeak(&candidates, checkCancellation: checkCancellation)
        var accepted: [Source] = []
        let separation = max(minSeparation, 0)
        let sepSq = Double(separation) * Double(separation)
        var cells: [Cell: [Source]] = [:]
        for c in candidates {
            try checkCancellation()
            var ok = true
            if separation > 0 {
                let cell = Cell(x: Int(c.x) / separation, y: Int(c.y) / separation)
                for dy in -1...1 {
                    for dx in -1...1 {
                        for a in cells[Cell(x: cell.x + dx, y: cell.y + dy)] ?? [] {
                            let distanceX = c.x - a.x, distanceY = c.y - a.y
                            if distanceX * distanceX + distanceY * distanceY < sepSq {
                                ok = false
                                break
                            }
                        }
                        if !ok { break }
                    }
                    if !ok { break }
                }
                if ok { cells[cell, default: []].append(c) }
            }
            if ok { accepted.append(c) }
        }
        // 3) Sub-pixel peak refinement via parabolic interpolation along each axis.
        //    Closed form for the maximum of a parabola through three samples:
        //      x_offset = 0.5 * (v[-1] − v[+1]) / (v[-1] − 2 v[0] + v[+1])
        //    Gives sub-pixel accuracy for Gaussian-like peaks without the central
        //    bias of intensity-weighted centroids when the peak is between pixels.
        var refined: [Source] = []
        refined.reserveCapacity(accepted.count)
        for src in accepted {
            try checkCancellation()
            let ix = Int(src.x), iy = Int(src.y)
            let v0 = image.physicalValue(x: ix, y: iy)
            let vL = image.physicalValue(x: ix - 1, y: iy)
            let vR = image.physicalValue(x: ix + 1, y: iy)
            let vD = image.physicalValue(x: ix, y: iy - 1)
            let vU = image.physicalValue(x: ix, y: iy + 1)
            var fx = 0.0, fy = 0.0
            let denomX = vL - 2 * v0 + vR
            if !vL.isNaN, !vR.isNaN, abs(denomX) > 1e-12 {
                fx = 0.5 * (vL - vR) / denomX
                if !fx.isFinite || abs(fx) > 1 { fx = 0 }
            }
            let denomY = vD - 2 * v0 + vU
            if !vD.isNaN, !vU.isNaN, abs(denomY) > 1e-12 {
                fy = 0.5 * (vD - vU) / denomY
                if !fy.isFinite || abs(fy) > 1 { fy = 0 }
            }
            refined.append(Source(x: Double(ix) + fx, y: Double(iy) + fy, peak: src.peak))
        }
        return refined
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    /// Bottom-up merge sort keeps the long candidate ordering phase cancellable.
    private static func sortByPeak(
        _ sources: inout [Source], checkCancellation: () throws -> Void
    ) throws {
        guard sources.count > 1 else { return }
        var buffer = sources
        var width = 1
        while width < sources.count {
            var start = 0
            while start < sources.count {
                try checkCancellation()
                let mid = min(start + width, sources.count)
                let end = min(mid + width, sources.count)
                var left = start, right = mid
                for index in start..<end {
                    if index & 8_191 == 0 { try checkCancellation() }
                    if right == end || (left < mid && sources[left].peak >= sources[right].peak) {
                        buffer[index] = sources[left]
                        left += 1
                    } else {
                        buffer[index] = sources[right]
                        right += 1
                    }
                }
                start = end
            }
            swap(&sources, &buffer)
            guard width <= sources.count / 2 else { break }
            width *= 2
        }
    }

    /// Median + 1.4826·MAD-based threshold over a `(2*half+1)²` box centred at
    /// `(x, y)`. MAD (median absolute deviation) is robust against outliers, so
    /// real sources in the box don't inflate the sigma estimate.
    private static func localCutoff(
        image: FITSImage, x: Int, y: Int, half: Int, nSigma: Double,
        checkCancellation: () throws -> Void
    ) throws -> Double {
        let xLo = max(0, x - half), xHi = min(image.width - 1, x + half)
        let yLo = max(0, y - half), yHi = min(image.height - 1, y + half)
        var values: [Double] = []
        values.reserveCapacity((xHi - xLo + 1) * (yHi - yLo + 1))
        for yy in yLo...yHi {
            try checkCancellation()
            for xx in xLo...xHi {
                let v = image.physicalValue(x: xx, y: yy)
                if !v.isNaN { values.append(v) }
            }
        }
        guard values.count >= 5 else { return -.infinity }
        try checkCancellation()
        values.sort()
        let median = values[values.count / 2]
        var deviations = values.map { abs($0 - median) }
        try checkCancellation()
        deviations.sort()
        try checkCancellation()
        let mad = deviations[deviations.count / 2]
        let sigma = 1.4826 * mad
        return median + nSigma * sigma
    }
}
