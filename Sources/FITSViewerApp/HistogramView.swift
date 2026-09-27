import SwiftUI
import FITSCore
import FITSRender
import TheiaKit

/// Histogram with two draggable vertical handles wired to the displayed levels.
struct HistogramView: View {
    let model: ScaleParametersModel
    let viewport: ImageViewState

    private static let handleWidth: CGFloat = 8
    @State private var dragStartVmin: Double?
    @State private var dragStartVmax: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.85))
                    if model.histogram != nil, model.dataMax > model.dataMin {
                        bars(geo: geo)
                        shadedRegion(width: w, height: h)
                        handle(x: xForValue(Double(viewport.vmin), width: w),
                               height: h, label: "vmin",
                               onDrag: { dx in moveVmin(dx, width: w) },
                               onEnd: { dragStartVmin = nil })
                        handle(x: xForValue(Double(viewport.vmax), width: w),
                               height: h, label: "vmax",
                               onDrag: { dx in moveVmax(dx, width: w) },
                               onEnd: { dragStartVmax = nil })
                    } else {
                        Text(model.histogramPlaceholder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            }
            .frame(height: 120)
            .cornerRadius(4)
            HStack {
                Text(ScaleParametersModel.formatHistogramValue(Double(viewport.vmin)))
                Spacer()
                Text(model.histogramRangeLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ScaleParametersModel.formatHistogramValue(Double(viewport.vmax)))
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    @ViewBuilder
    private func bars(geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let barW = w / CGFloat(model.barHeights.count)
        Canvas { context, _ in
            for (i, height) in model.barHeights.enumerated() {
                guard height > 0 else { continue }
                let barH = CGFloat(height) * h
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

    private func handle(x: CGFloat, height h: CGFloat, label: String,
                        onDrag: @escaping (CGFloat) -> Void,
                        onEnd: @escaping () -> Void) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: Self.handleWidth, height: h)
            .offset(x: x - Self.handleWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in onDrag(value.translation.width) }
                    .onEnded { _ in onEnd() }
            )
            .help(label)
    }

    private func xForValue(_ v: Double, width w: CGFloat) -> CGFloat {
        CGFloat(model.xForValue(v, width: Double(w)))
    }

    private func moveVmin(_ dx: CGFloat, width w: CGFloat) {
        let start = dragStartVmin ?? Double(viewport.vmin)
        dragStartVmin = start
        viewport.vmin = Float(model.movedVmin(
            current: start, vmax: Double(viewport.vmax),
            deltaX: Double(dx), width: Double(w)
        ))
    }

    private func moveVmax(_ dx: CGFloat, width w: CGFloat) {
        let start = dragStartVmax ?? Double(viewport.vmax)
        dragStartVmax = start
        viewport.vmax = Float(model.movedVmax(
            current: start, vmin: Double(viewport.vmin),
            deltaX: Double(dx), width: Double(w)
        ))
    }
}
