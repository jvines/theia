import SwiftUI
import FITSCore

/// Generic 1D line plot for profile / spectrum data.
struct ProfilePlotView: View {
    let title: String
    let xLabel: String
    let yLabel: String
    let xValues: [Double]
    let yValues: [Double]
    let highlightX: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            GeometryReader { geo in
                Canvas { ctx, size in
                    draw(in: ctx, size: size)
                }
                .background(Color.black.opacity(0.85))
                .cornerRadius(4)
                .overlay(alignment: .topLeading) {
                    if let r = stats {
                        Text(String(format: "min %.4g  max %.4g  mean %.4g  n=%d",
                                    r.min, r.max, r.mean, r.count))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(6)
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                Text(xLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(yLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stats: (min: Double, max: Double, mean: Double, count: Int)? {
        let clean = yValues.filter { !$0.isNaN }
        guard !clean.isEmpty else { return nil }
        return (clean.min()!, clean.max()!, clean.reduce(0, +) / Double(clean.count), clean.count)
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let pad = CGFloat(20)
        let plotW = size.width - 2 * pad
        let plotH = size.height - 2 * pad
        guard plotW > 0, plotH > 0, !xValues.isEmpty else { return }
        let xMin = xValues.min() ?? 0, xMax = xValues.max() ?? 1
        let xSpan = max(xMax - xMin, 1e-12)
        let cleanY = yValues.filter { !$0.isNaN }
        let yMin = cleanY.min() ?? 0, yMax = cleanY.max() ?? 1
        let ySpan = max(yMax - yMin, 1e-12)
        func mapX(_ x: Double) -> CGFloat {
            pad + CGFloat((x - xMin) / xSpan) * plotW
        }
        func mapY(_ y: Double) -> CGFloat {
            size.height - pad - CGFloat((y - yMin) / ySpan) * plotH
        }
        // Axes
        var axis = Path()
        axis.move(to: CGPoint(x: pad, y: pad))
        axis.addLine(to: CGPoint(x: pad, y: size.height - pad))
        axis.addLine(to: CGPoint(x: size.width - pad, y: size.height - pad))
        ctx.stroke(axis, with: .color(.white.opacity(0.3)), lineWidth: 1)
        // Data line (skip across NaNs)
        var line = Path()
        var lifted = true
        for i in 0..<xValues.count {
            let y = yValues[i]
            if y.isNaN { lifted = true; continue }
            let p = CGPoint(x: mapX(xValues[i]), y: mapY(y))
            if lifted { line.move(to: p); lifted = false }
            else { line.addLine(to: p) }
        }
        ctx.stroke(line, with: .color(.cyan), lineWidth: 1.5)
        // Highlight (e.g. current plane for spectrum)
        if let hx = highlightX {
            var mark = Path()
            mark.move(to: CGPoint(x: mapX(hx), y: pad))
            mark.addLine(to: CGPoint(x: mapX(hx), y: size.height - pad))
            ctx.stroke(mark, with: .color(.yellow.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}
