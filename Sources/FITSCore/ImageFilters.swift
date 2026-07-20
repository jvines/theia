import Foundation

/// 2D image filters returning new `FITSImage` instances (float32-backed).
/// Edge handling: clamp-to-edge (a pixel at the boundary uses its in-bounds
/// neighbourhood only).
public enum ImageFilters {
    /// N×N mean filter. `size` should be an odd integer ≥ 3.
    public static func boxcar(_ image: FITSImage, size: Int) -> FITSImage {
        precondition(size >= 1 && size % 2 == 1, "boxcar size must be odd ≥ 1")
        let half = size / 2
        return convolveNonSeparable(image) { x, y, w, h, get in
            var sum = 0.0
            var n = 0
            for dy in -half...half {
                let yy = max(0, min(h - 1, y + dy))
                for dx in -half...half {
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
        precondition(size >= 1 && size % 2 == 1, "median size must be odd ≥ 1")
        let half = size / 2
        return convolveNonSeparable(image) { x, y, w, h, get in
            var buf: [Double] = []
            buf.reserveCapacity(size * size)
            for dy in -half...half {
                let yy = max(0, min(h - 1, y + dy))
                for dx in -half...half {
                    let xx = max(0, min(w - 1, x + dx))
                    let v = get(xx, yy)
                    if !v.isNaN { buf.append(v) }
                }
            }
            if buf.isEmpty { return .nan }
            buf.sort()
            let n = buf.count
            return Float(n % 2 == 1 ? buf[n / 2] : (buf[n / 2 - 1] + buf[n / 2]) / 2)
        }
    }

    /// Separable Gaussian with the given sigma (in pixels). Kernel half-width =
    /// `ceil(3 * sigma)` so the truncation error is negligible.
    public static func gaussian(_ image: FITSImage, sigma: Double) -> FITSImage {
        precondition(sigma > 0, "sigma must be > 0")
        let radius = max(1, Int(ceil(3 * sigma)))
        let twoSigSq = 2 * sigma * sigma
        var weights = [Double](repeating: 0, count: 2 * radius + 1)
        var wSum = 0.0
        for (k, d) in (-radius...radius).enumerated() {
            let w = exp(-Double(d * d) / twoSigSq)
            weights[k] = w; wSum += w
        }
        for i in weights.indices { weights[i] /= wSum }

        let w = image.width, h = image.height
        // Horizontal pass into a temp Float buffer.
        var tmp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                var wAccum = 0.0
                for k in -radius...radius {
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
            for x in 0..<w {
                var sum = 0.0
                var wAccum = 0.0
                for k in -radius...radius {
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
        kernel: (_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ get: (Int, Int) -> Double) -> Float
    ) -> FITSImage {
        let w = image.width, h = image.height
        var out = [Float](repeating: 0, count: w * h)
        let get = { (xx: Int, yy: Int) in image.physicalValue(x: xx, y: yy) }
        for y in 0..<h {
            for x in 0..<w {
                out[y * w + x] = kernel(x, y, w, h, get)
            }
        }
        return .fromFloat32(pixels: out, width: w, height: h)
    }
}
