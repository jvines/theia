import Foundation

/// 2D image filters returning new `FITSImage` instances (float32-backed).
/// Edge handling: clamp-to-edge (a pixel at the boundary uses its in-bounds
/// neighbourhood only).
public enum ImageFilters {
    /// N×N mean filter. `size` should be an odd integer ≥ 3.
    public static func boxcar(_ image: FITSImage, size: Int) -> FITSImage {
        try! boxcarCheckingCancellation(image, size: size, checkCancellation: {})
    }

    /// Mean filter that checks for cancellation during each row and large neighbourhood.
    public static func boxcarCheckingCancellation(
        _ image: FITSImage, size: Int,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> FITSImage {
        precondition(size >= 1 && size % 2 == 1, "boxcar size must be odd ≥ 1")
        let half = size / 2
        return try convolveNonSeparable(image, checkCancellation: checkCancellation) { x, y, w, h, get in
            var sum = 0.0
            var n = 0
            var sampled = 0
            for dy in -half...half {
                let yy = max(0, min(h - 1, y + dy))
                for dx in -half...half {
                    if sampled > 0 && sampled % 256 == 0 { try checkCancellation() }
                    sampled += 1
                    let xx = max(0, min(w - 1, x + dx))
                    let v = get(xx, yy)
                    if v.isNaN { continue }
                    sum += v; n += 1
                }
            }
            return n == 0 ? .nan : Float(sum / Double(n))
        }
    }

    /// N×N median filter. `size` should be an odd integer ≥ 3.
    public static func median(_ image: FITSImage, size: Int) -> FITSImage {
        try! medianCheckingCancellation(image, size: size, checkCancellation: {})
    }

    /// Median filter that checks while gathering and sorting each neighbourhood.
    public static func medianCheckingCancellation(
        _ image: FITSImage, size: Int,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> FITSImage {
        precondition(size >= 1 && size % 2 == 1, "median size must be odd ≥ 1")
        let half = size / 2
        return try convolveNonSeparable(image, checkCancellation: checkCancellation) { x, y, w, h, get in
            var buf: [Double] = []
            buf.reserveCapacity(size * size)
            var sampled = 0
            for dy in -half...half {
                let yy = max(0, min(h - 1, y + dy))
                for dx in -half...half {
                    if sampled > 0 && sampled % 256 == 0 { try checkCancellation() }
                    sampled += 1
                    let xx = max(0, min(w - 1, x + dx))
                    let v = get(xx, yy)
                    if !v.isNaN { buf.append(v) }
                }
            }
            if buf.isEmpty { return .nan }
            try checkCancellation()
            try sortCheckingCancellation(&buf, checkCancellation: checkCancellation)
            let n = buf.count
            return Float(n % 2 == 1 ? buf[n / 2] : (buf[n / 2 - 1] + buf[n / 2]) / 2)
        }
    }

    /// Separable Gaussian with the given sigma (in pixels). Kernel half-width =
    /// `ceil(3 * sigma)` so the truncation error is negligible.
    public static func gaussian(_ image: FITSImage, sigma: Double) -> FITSImage {
        try! gaussianCheckingCancellation(image, sigma: sigma, checkCancellation: {})
    }

    /// Gaussian filter that checks while constructing its kernel and in both passes.
    public static func gaussianCheckingCancellation(
        _ image: FITSImage, sigma: Double,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> FITSImage {
        precondition(sigma > 0, "sigma must be > 0")
        try checkCancellation()
        let radius = max(1, Int(ceil(3 * sigma)))
        let twoSigSq = 2 * sigma * sigma
        var weights = [Double](repeating: 0, count: 2 * radius + 1)
        var wSum = 0.0
        for (k, d) in (-radius...radius).enumerated() {
            if k > 0 && k % 256 == 0 { try checkCancellation() }
            let w = exp(-Double(d * d) / twoSigSq)
            weights[k] = w; wSum += w
        }
        for i in weights.indices { weights[i] /= wSum }

        let w = image.width, h = image.height
        // Horizontal pass into a temp Float buffer.
        var tmp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            try checkCancellation()
            for x in 0..<w {
                if x > 0 && x % 256 == 0 { try checkCancellation() }
                var sum = 0.0
                var wAccum = 0.0
                for k in -radius...radius {
                    if k != -radius && (k + radius) % 256 == 0 { try checkCancellation() }
                    let xx = max(0, min(w - 1, x + k))
                    let v = image.physicalValue(x: xx, y: y)
                    if v.isNaN { continue }
                    sum += weights[k + radius] * v
                    wAccum += weights[k + radius]
                }
                tmp[y * w + x] = wAccum > 0 ? Float(sum / wAccum) : .nan
            }
        }
        // Vertical pass into the output Float buffer.
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            try checkCancellation()
            for x in 0..<w {
                if x > 0 && x % 256 == 0 { try checkCancellation() }
                var sum = 0.0
                var wAccum = 0.0
                for k in -radius...radius {
                    if k != -radius && (k + radius) % 256 == 0 { try checkCancellation() }
                    let yy = max(0, min(h - 1, y + k))
                    let v = tmp[yy * w + x]
                    if v.isNaN { continue }
                    sum += weights[k + radius] * Double(v)
                    wAccum += weights[k + radius]
                }
                out[y * w + x] = wAccum > 0 ? Float(sum / wAccum) : .nan
            }
        }
        return .fromFloat32(pixels: out, width: w, height: h)
    }

    /// Generic non-separable convolution scaffold used by boxcar/median.
    private static func convolveNonSeparable(
        _ image: FITSImage,
        checkCancellation: () throws -> Void,
        kernel: (_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ get: (Int, Int) -> Double) throws -> Float
    ) throws -> FITSImage {
        try checkCancellation()
        let w = image.width, h = image.height
        var out = [Float](repeating: 0, count: w * h)
        let get = { (xx: Int, yy: Int) in image.physicalValue(x: xx, y: yy) }
        for y in 0..<h {
            try checkCancellation()
            for x in 0..<w {
                if x > 0 && x % 256 == 0 { try checkCancellation() }
                out[y * w + x] = try kernel(x, y, w, h, get)
            }
        }
        return .fromFloat32(pixels: out, width: w, height: h)
    }

    /// Small kernels use the standard sort. Large kernels use merge sort so a
    /// cancelled task need not wait for one potentially long sort to finish.
    private static func sortCheckingCancellation(
        _ values: inout [Double], checkCancellation: () throws -> Void
    ) throws {
        guard values.count > 256 else {
            values.sort()
            return
        }
        var scratch = values
        var runWidth = 1
        while runWidth < values.count {
            var start = 0
            while start < values.count {
                let middle = min(start + runWidth, values.count)
                let end = min(middle + runWidth, values.count)
                var left = start
                var right = middle
                for output in start..<end {
                    if output % 256 == 0 { try checkCancellation() }
                    if left < middle && (right == end || values[left] <= values[right]) {
                        scratch[output] = values[left]
                        left += 1
                    } else {
                        scratch[output] = values[right]
                        right += 1
                    }
                }
                start = end
            }
            swap(&values, &scratch)
            runWidth *= 2
        }
    }
}
