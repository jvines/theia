import SwiftUI
import FITSCore
import FITSRender
import TheiaKit

/// Histogram of physical pixel values with two draggable vertical handles wired to
/// `viewport.vmin` and `viewport.vmax`. Computed lazily from the supplied values.
struct HistogramView: View {
    let physicalValues: [Double]
    let viewport: ImageViewState

    private static let bins = 256
    private static let handleWidth: CGFloat = 8

    @State private var dataMin: Double = .nan
    @State private var dataMax: Double = .nan
    @State private var histogram: Histogram?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.85))
                    if let histogram, let maxCount = histogram.counts.max(), maxCount > 0,
                       dataMax > dataMin {
                        bars(geo: geo, histogram: histogram, maxCount: maxCount)
                        shadedRegion(width: w, height: h)
                        handle(x: xForValue(Double(viewport.vmin), width: w),
                               height: h, label: "vmin") { dx in moveVmin(dx, width: w) }
                        handle(x: xForValue(Double(viewport.vmax), width: w),
                               height: h, label: "vmax") { dx in moveVmax(dx, width: w) }
                    } else {
                        Text("Computing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            }
            .frame(height: 120)
            .cornerRadius(4)
            HStack {
                Text(format(Double(viewport.vmin)))
                Spacer()
                Text(rangeLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(format(Double(viewport.vmax)))
            }
            .font(.system(.caption, design: .monospaced))
        }
        .onAppear(perform: rebuild)
    }

    @ViewBuilder
    private func bars(geo: GeometryProxy, histogram: Histogram, maxCount: Int) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let scale = Double(maxCount)
        let barW = w / CGFloat(histogram.counts.count)
        // Log-scaled height: faint bins still visible.
        Canvas { context, _ in
            for (i, c) in histogram.counts.enumerated() {
                guard c > 0 else { continue }
                let nh = log10(Double(c) + 1) / log10(scale + 1)
                let barH = CGFloat(nh) * h
                let rect = CGRect(
                    x: CGFloat(i) * barW,
                    y: h - barH,
                    width: max(barW - 0.5, 0.5),
                    height: barH
                )
                context.fill(Path(rect), with: .color(Color(white: 0.85)))
            }
        }
    }

    private func shadedRegion(width w: CGFloat, height h: CGFloat) -> some View {
        let xLo = xForValue(Double(viewport.vmin), width: w)
        let xHi = xForValue(Double(viewport.vmax), width: w)
        return Path { p in
            p.addRect(CGRect(x: xLo, y: 0, width: max(xHi - xLo, 0), height: h))
        }
        .fill(Color.accentColor.opacity(0.18))
    }

    private func handle(x: CGFloat, height h: CGFloat, label: String, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: Self.handleWidth, height: h)
            .offset(x: x - Self.handleWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in onDrag(value.translation.width) }
            )
            .help(label)
    }

    private func rebuild() {
        guard let r = PixelStatistics.minMax(physicalValues) else {
            dataMin = .nan; dataMax = .nan; histogram = nil; return
        }
        dataMin = r.min; dataMax = r.max
        if r.min < r.max {
            histogram = PixelStatistics.histogram(physicalValues, bins: Self.bins, range: r.min...r.max)
        } else {
            histogram = nil
        }
    }

    private func xForValue(_ v: Double, width w: CGFloat) -> CGFloat {
        guard dataMax > dataMin else { return 0 }
        let t = (v - dataMin) / (dataMax - dataMin)
        return CGFloat(max(0, min(1, t))) * w
    }

    private func valueForX(_ x: CGFloat, width w: CGFloat) -> Double {
        guard w > 0, dataMax > dataMin else { return dataMin }
        let t = Double(max(0, min(w, x)) / w)
        return dataMin + t * (dataMax - dataMin)
    }

    private func moveVmin(_ dx: CGFloat, width w: CGFloat) {
        let curX = xForValue(Double(viewport.vmin), width: w)
        let newV = valueForX(curX + dx, width: w)
        viewport.vmin = Float(min(newV, Double(viewport.vmax) - 1e-9))
    }

    private func moveVmax(_ dx: CGFloat, width w: CGFloat) {
        let curX = xForValue(Double(viewport.vmax), width: w)
        let newV = valueForX(curX + dx, width: w)
        viewport.vmax = Float(max(newV, Double(viewport.vmin) + 1e-9))
    }

    private var rangeLabel: String {
        guard dataMin.isFinite, dataMax.isFinite else { return "" }
        return "data \(format(dataMin)) … \(format(dataMax))"
    }

    private func format(_ v: Double) -> String {
        if !v.isFinite { return "—" }
        if abs(v) >= 1e4 || (v != 0 && abs(v) < 0.01) { return String(format: "%.3e", v) }
        return String(format: "%.4g", v)
    }
}
