import Foundation

/// Circular 2D Gaussian fit (σx == σy) over a small box around an initial guess.
///
/// Model: `f(x, y) = A · exp(-((x-x0)² + (y-y0)²) / (2σ²)) + B`
///
/// Uses Levenberg-Marquardt with numeric Jacobian. Surfaces sub-pixel centroid,
/// FWHM, amplitude and background — the standard summary for a single source.
/// A more-general elliptical fit (with rotation) is a future extension.
public enum GaussianFit {
    public struct Result: Sendable, Equatable {
        public let x: Double        // 0-based image pixel
        public let y: Double
        public let sigmaX: Double   // pixels
        public let sigmaY: Double
        public let amplitude: Double
        public let background: Double

        public var fwhm: Double { 2 * Foundation.sqrt(2 * Foundation.log(2)) * (sigmaX + sigmaY) / 2 }
    }

    /// Fit centred around `near`, sampling pixels in `(2*boxRadius+1)²`.
    public static func fit(image: FITSImage, near: (Int, Int), boxRadius: Int) -> Result? {
        let xLo = Swift.max(0, near.0 - boxRadius), xHi = Swift.min(image.width - 1, near.0 + boxRadius)
        let yLo = Swift.max(0, near.1 - boxRadius), yHi = Swift.min(image.height - 1, near.1 + boxRadius)
        guard xLo <= xHi, yLo <= yHi else { return nil }
        var pts: [(Double, Double, Double)] = []
        for y in yLo...yHi {
            for x in xLo...xHi {
                let v = image.physicalValue(x: x, y: y)
                if v.isNaN { continue }
                pts.append((Double(x), Double(y), v))
            }
        }
        guard pts.count >= 6 else { return nil }
        // Initial guess.
        let values = pts.map(\.2)
        let bg = values.min() ?? 0
        let amp = (values.max() ?? bg) - bg
        guard amp > 0 else { return nil }
        var p: [Double] = [
            amp,                   // A
            Double(near.0),        // x0
            Double(near.1),        // y0
            2.0,                   // σ
            bg                     // B
        ]

        // Levenberg-Marquardt with numeric central-difference Jacobian.
        var lambda = 1e-3
        var prevRSS = rss(pts: pts, params: p)
        for _ in 0..<60 {
            let (jtj, jtr) = normalEquations(pts: pts, params: p)
            var delta: [Double]?
            // Try with current lambda; if that fails (matrix singular or step worsens), bump.
            for _ in 0..<6 {
                var lhs = jtj
                for i in 0..<5 { lhs[i][i] *= (1 + lambda) }
                if let d = solve5x5(lhs: lhs, rhs: jtr) {
                    let trial = zip(p, d).map(+)
                    let newRSS = rss(pts: pts, params: trial)
                    if newRSS < prevRSS {
                        p = trial
                        prevRSS = newRSS
                        lambda = Swift.max(lambda * 0.5, 1e-10)
                        delta = d
                        break
                    }
                }
                lambda *= 4
            }
            if delta == nil { break }
            // Convergence check: tiny parameter step in pixel units.
            let dx = delta![1], dy = delta![2], dSig = delta![3]
            if abs(dx) < 1e-5 && abs(dy) < 1e-5 && abs(dSig) < 1e-5 { break }
        }
        let sigma = abs(p[3])
        guard sigma > 0 else { return nil }
        return Result(x: p[1], y: p[2], sigmaX: sigma, sigmaY: sigma,
                      amplitude: p[0], background: p[4])
    }

    // MARK: - LM internals

    /// Model + per-parameter partial derivatives at (px, py).
    private static func modelAndGrad(_ px: Double, _ py: Double, _ p: [Double]) -> (Double, [Double]) {
        let A = p[0], x0 = p[1], y0 = p[2], sigma = p[3], B = p[4]
        let dx = px - x0, dy = py - y0
        let r2 = dx * dx + dy * dy
        let s2 = sigma * sigma
        let e = exp(-r2 / (2 * s2))
        let f = A * e + B
        let dA  = e
        let dx0 = A * e * (dx / s2)
        let dy0 = A * e * (dy / s2)
        let dSi = A * e * (r2 / (sigma * s2))
        let dB: Double = 1.0
        return (f, [dA, dx0, dy0, dSi, dB])
    }

    private static func rss(pts: [(Double, Double, Double)], params: [Double]) -> Double {
        var s = 0.0
        for (px, py, v) in pts {
            let (f, _) = modelAndGrad(px, py, params)
            let r = v - f
            s += r * r
        }
        return s
    }

    private static func normalEquations(pts: [(Double, Double, Double)], params: [Double]) -> ([[Double]], [Double]) {
        var jtj = Array(repeating: Array(repeating: 0.0, count: 5), count: 5)
        var jtr = Array(repeating: 0.0, count: 5)
        for (px, py, v) in pts {
            let (f, g) = modelAndGrad(px, py, params)
            let r = v - f
            for i in 0..<5 {
                jtr[i] += g[i] * r
                for j in 0..<5 { jtj[i][j] += g[i] * g[j] }
            }
        }
        return (jtj, jtr)
    }

    /// Solve a 5×5 linear system via Gaussian elimination with partial pivoting.
    private static func solve5x5(lhs: [[Double]], rhs: [Double]) -> [Double]? {
        var a = lhs
        var b = rhs
        let n = 5
        for i in 0..<n {
            // Pivot.
            var pivot = i
            for k in (i + 1)..<n where abs(a[k][i]) > abs(a[pivot][i]) { pivot = k }
            if abs(a[pivot][i]) < 1e-12 { return nil }
            if pivot != i { a.swapAt(i, pivot); b.swapAt(i, pivot) }
            // Eliminate.
            for k in (i + 1)..<n {
                let factor = a[k][i] / a[i][i]
                for j in i..<n { a[k][j] -= factor * a[i][j] }
                b[k] -= factor * b[i]
            }
        }
        var x = Array(repeating: 0.0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[i]
            for j in (i + 1)..<n { sum -= a[i][j] * x[j] }
            x[i] = sum / a[i][i]
        }
        return x
    }
}
