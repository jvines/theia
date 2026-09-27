import SwiftUI
import FITSCore
import TheiaKit

/// Image-wide statistics: n, mean, median, σ, min/max, and 1/5/25/50/75/95/99 percentiles.
/// Computed for the current displayed image when opened or recomputed.
struct ImageStatsPanel: View {
    let session: DocumentSession
    private var model: ImageStatisticsModel { session.statistics }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stats = model.summary {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("n").foregroundStyle(.secondary)
                        Text("\(stats.n)").mono()
                        Text("dimensions").foregroundStyle(.secondary)
                        Text("\(stats.width) × \(stats.height)").mono()
                    }
                    GridRow {
                        Text("min").foregroundStyle(.secondary)
                        Text(ImageStatisticsSummary.format(stats.min)).mono()
                        Text("max").foregroundStyle(.secondary)
                        Text(ImageStatisticsSummary.format(stats.max)).mono()
                    }
                    GridRow {
                        Text("mean").foregroundStyle(.secondary)
                        Text(ImageStatisticsSummary.format(stats.mean)).mono()
                        Text("median").foregroundStyle(.secondary)
                        Text(ImageStatisticsSummary.format(stats.median)).mono()
                    }
                    GridRow {
                        Text("σ").foregroundStyle(.secondary)
                        Text(ImageStatisticsSummary.format(stats.stddev)).mono()
                        Text("NaN").foregroundStyle(.secondary)
                        Text("\(stats.nans)").mono()
                    }
                }
                Divider()
                Text("Percentiles").font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(stats.percentiles, id: \.percent) { row in
                        GridRow {
                            Text(String(format: "%.2f%%", row.percent)).foregroundStyle(.secondary)
                            Text(ImageStatisticsSummary.format(row.value)).mono()
                        }
                    }
                }
                Button("Recompute") { compute(force: true) }
                    .controlSize(.small)
            } else if model.isComputing {
                ProgressView("Computing…")
            } else {
                Button("Compute statistics") { compute(force: true) }
            }
        }
        .padding(8)
        .onAppear { compute(force: true) }
        .onChange(of: session.imageRevision) { _, _ in compute(force: true) }
    }

    private func compute(force: Bool) {
        model.refresh(image: session.displayed, imageRevision: session.imageRevision,
                      force: force)
    }
}

private extension Text {
    func mono() -> Text { font(.system(.body, design: .monospaced)) }
}
