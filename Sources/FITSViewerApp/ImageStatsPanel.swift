import SwiftUI
import FITSCore

/// Image-wide statistics: n, mean, median, σ, min/max, and 1/5/25/50/75/95/99 percentiles.
/// Computed lazily on first appearance for the current displayed image.
struct ImageStatsPanel: View {
    let imageProvider: () -> FITSImage?

    @State private var stats: Stats?
    @State private var computing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stats {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("n").foregroundStyle(.secondary)
                        Text("\(stats.n)").mono()
                        Text("dimensions").foregroundStyle(.secondary)
                        Text("\(stats.width) × \(stats.height)").mono()
                    }
                    GridRow {
                        Text("min").foregroundStyle(.secondary)
                        Text(fmt(stats.min)).mono()
                        Text("max").foregroundStyle(.secondary)
                        Text(fmt(stats.max)).mono()
                    }
                    GridRow {
                        Text("mean").foregroundStyle(.secondary)
                        Text(fmt(stats.mean)).mono()
                        Text("median").foregroundStyle(.secondary)
                        Text(fmt(stats.median)).mono()
                    }
                    GridRow {
                        Text("σ").foregroundStyle(.secondary)
                        Text(fmt(stats.stddev)).mono()
                        Text("NaN").foregroundStyle(.secondary)
                        Text("\(stats.nans)").mono()
                    }
                }
                Divider()
                Text("Percentiles").font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(zip(percentiles, stats.percentiles)), id: \.0) { (p, v) in
                        GridRow {
                            Text(String(format: "%.2f%%", p)).foregroundStyle(.secondary)
                            Text(fmt(v)).mono()
                        }
                    }
                }
                Button("Recompute") { self.stats = nil; compute() }
                    .controlSize(.small)
            } else if computing {
                ProgressView("Computing…")
            } else {
                Button("Compute statistics") { compute() }
            }
        }
        .padding(8)
        .onAppear { if stats == nil { compute() } }
    }

    private let percentiles: [Double] = [0.5, 1, 5, 25, 50, 75, 95, 99, 99.5]

    private struct Stats {
        let width: Int, height: Int
        let n: Int, nans: Int
        let min: Double, max: Double, mean: Double, median: Double, stddev: Double
        let percentiles: [Double]
    }

    private func compute() {
        guard !computing else { return }
        guard let image = imageProvider() else { return }
        computing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let values = image.physicalValues()
            let nansCount = values.filter { $0.isNaN }.count
            var clean = values.filter { !$0.isNaN }
            clean.sort()
            let n = clean.count
            let sum = clean.reduce(0, +)
            let mean = n == 0 ? 0 : sum / Double(n)
            let median = n == 0 ? 0 : clean[n / 2]
            let variance = n <= 1 ? 0 : clean.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
            let std = variance.squareRoot()
            func pctile(_ p: Double) -> Double {
                guard !clean.isEmpty else { return .nan }
                let idx = max(0, min(n - 1, Int((p / 100) * Double(n - 1))))
                return clean[idx]
            }
            let result = Stats(
                width: image.width, height: image.height,
                n: n, nans: nansCount,
                min: clean.first ?? 0, max: clean.last ?? 0,
                mean: mean, median: median, stddev: std,
                percentiles: percentiles.map(pctile)
            )
            DispatchQueue.main.async {
                stats = result
                computing = false
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        if abs(v) >= 1e4 || (v != 0 && abs(v) < 0.01) { return String(format: "%.4g", v) }
        return String(format: "%.4f", v)
    }
}

private extension Text {
    func mono() -> Text { font(.system(.body, design: .monospaced)) }
}
