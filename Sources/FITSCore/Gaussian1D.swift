import Foundation

/// 1D Gaussian + baseline fit, used by the spectrum line-fit feature.
/// Model: `f(x) = baseline + amplitude · exp(-(x - center)² / (2σ²))`
public enum Gaussian1D {
    public struct Result: Sendable, Equatable {
        public let center: Double
        public let sigma: Double
        public let amplitude: Double
        public let baseline: Double
        public var fwhm: Double { 2 * Foundation.sqrt(2 * Foundation.log(2)) * sigma }
    }

    /// Levenberg-Marquardt fit over the `xs` channels within `halfWidth` of `near`.
    /// Both axes are arbitrary units (Å, channels, m/s, …).
    public static func fit(xs: [Double], ys: [Double], near: Double, halfWidth: Double) -> Result? {
        precondition(xs.count == ys.count, "xs / ys length mismatch")
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(xs.count)
        for i in xs.indices {
            if abs(xs[i] - near) <= halfWidth, !ys[i].isNaN { pts.append((xs[i], ys[i])) }
        }
        guard pts.count >= 4 else { return nil }
        let yVals = pts.map(\.1)
        let baseline0 = yVals.min() ?? 0
        let amp0 = (yVals.max() ?? baseline0) - baseline0
        if amp0 == 0 { return nil }
        // Initial sigma: half-width-at-half-max guess (rough).
        var p: [Double] = [near, max(halfWidth / 4, 1), amp0, baseline0]
        var lambda = 1e-3
        var prevRSS = rss(pts: pts, p: p)
        for _ in 0..<60 {
            let (jtj, jtr) = normal(pts: pts, p: p)
            var stepped = false
            for _ in 0..<6 {
                var lhs = jtj
                for i in 0..<4 { lhs[i][i] *= (1 + lambda) }
                if let d = solve4(lhs: lhs, rhs: jtr) {
                    let trial = zip(p, d).map(+)
                    let newRSS = rss(pts: pts, p: trial)
                    if newRSS < prevRSS {
                        p = trial; prevRSS = newRSS
                        lambda = max(lambda * 0.5, 1e-10)
                        stepped = true
                        break
                    }
                }
                lambda *= 4
            }
            if !stepped { break }
        }
        let sigma = abs(p[1])
        guard sigma > 0 else { return nil }
        return Result(center: p[0], sigma: sigma, amplitude: p[2], baseline: p[3])
    }

    private static func eval(_ x: Double, _ p: [Double]) -> (Double, [Double]) {
        let c = p[0], sigma = p[1], amp = p[2], b = p[3]
        let dx = x - c
        let s2 = sigma * sigma
        let e = exp(-dx * dx / (2 * s2))
        let f = b + amp * e
        let dC = amp * e * (dx / s2)
        let dS = amp * e * (dx * dx / (sigma * s2))
        let dA = e
        let dB: Double = 1
        return (f, [dC, dS, dA, dB])
    }

    private static func rss(pts: [(Double, Double)], p: [Double]) -> Double {
        var s = 0.0
        for (x, y) in pts {
            let (f, _) = eval(x, p)
            let r = y - f
            s += r * r
        }
        return s
    }

    private static func normal(pts: [(Double, Double)], p: [Double]) -> ([[Double]], [Double]) {
        var jtj = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        var jtr = Array(repeating: 0.0, count: 4)
        for (x, y) in pts {
            let (f, g) = eval(x, p)
            let r = y - f
            for i in 0..<4 {
                jtr[i] += g[i] * r
                for j in 0..<4 { jtj[i][j] += g[i] * g[j] }
            }
        }
        return (jtj, jtr)
    }

    private static func solve4(lhs: [[Double]], rhs: [Double]) -> [Double]? {
        var a = lhs
        var b = rhs
        let n = 4
        for i in 0..<n {
            var pivot = i
            for k in (i + 1)..<n where abs(a[k][i]) > abs(a[pivot][i]) { pivot = k }
            if abs(a[pivot][i]) < 1e-12 { return nil }
            if pivot != i { a.swapAt(i, pivot); b.swapAt(i, pivot) }
            for k in (i + 1)..<n {
                let f = a[k][i] / a[i][i]
                for j in i..<n { a[k][j] -= f * a[i][j] }
                b[k] -= f * b[i]
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
