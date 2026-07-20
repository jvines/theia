import SwiftUI
import simd
import FITSCore
import FITSRender

/// Shows the geometry (line, circle, etc) of the most-recent profile request so
/// the user can see what was sampled. Updated by DocumentView whenever a profile
/// is generated; cleared when the matching window closes.
enum ProfileGeometry: Equatable {
    case line(from: SIMD2<Double>, to: SIMD2<Double>)
    case radial(center: SIMD2<Double>, maxRadius: Double)
    case growth(center: SIMD2<Double>, maxRadius: Double)
    case point(SIMD2<Double>)   // cube spectrum at pixel
}

struct ProfileGeometryOverlay: View {
    let geometry: ProfileGeometry?
    @ObservedObject var viewport: ViewportObservable

    var body: some View {
        Canvas { ctx, size in
            guard let g = geometry else { return }
            let t = viewport.transform
            func toCanvas(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(x: t.scale * p.x + t.translation.x,
                        y: size.height - (t.scale * p.y + t.translation.y))
            }
            let stroke = Color(red: 1.0, green: 0.85, blue: 0.30)   // gold — distinct from regions
            switch g {
            case .line(let from, let to):
                let a = toCanvas(from), b = toCanvas(to)
                var path = Path(); path.move(to: a); path.addLine(to: b)
                ctx.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                // Tick marks at each end.
                drawTick(ctx: ctx, at: a, color: stroke)
                drawTick(ctx: ctx, at: b, color: stroke)
                // Midpoint label with length.
                let dx = to.x - from.x, dy = to.y - from.y
                let len = (dx * dx + dy * dy).squareRoot()
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                drawLabel(ctx: ctx, at: mid, text: String(format: "%.1f px", len), color: stroke)
            case .radial(let center, let maxR), .growth(let center, let maxR):
                let c = toCanvas(center)
                let r = CGFloat(t.scale * maxR)
                // Centre crosshair.
                drawTick(ctx: ctx, at: c, color: stroke)
                // Outer ring at maxRadius.
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.stroke(ring, with: .color(stroke), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                let labelText: String
                if case .growth = g { labelText = String(format: "growth ≤ %.1f px", maxR) }
                else { labelText = String(format: "radial ≤ %.1f px", maxR) }
                drawLabel(ctx: ctx, at: CGPoint(x: c.x, y: c.y - r - 12),
                          text: labelText, color: stroke)
            case .point(let p):
                let c = toCanvas(p)
                drawTick(ctx: ctx, at: c, color: stroke)
                drawLabel(ctx: ctx, at: CGPoint(x: c.x, y: c.y - 12),
                          text: String(format: "(%.1f, %.1f)", p.x, p.y), color: stroke)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawTick(ctx: GraphicsContext, at p: CGPoint, color: Color) {
        let r: CGFloat = 6
        var path = Path()
        path.move(to: CGPoint(x: p.x - r, y: p.y))
        path.addLine(to: CGPoint(x: p.x + r, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - r))
        path.addLine(to: CGPoint(x: p.x, y: p.y + r))
        ctx.stroke(path, with: .color(color), lineWidth: 1.2)
    }

    private func drawLabel(ctx: GraphicsContext, at p: CGPoint, text: String, color: Color) {
        let attr = AttributedString(text, attributes: AttributeContainer([
            .foregroundColor: NSColor(color),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        ]))
        // Tiny black backdrop for legibility.
        let bg = AttributedString("       \(text)       ", attributes: AttributeContainer([
            .foregroundColor: NSColor.black.withAlphaComponent(0.5),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        ]))
        _ = bg
        ctx.draw(Text(attr), at: p, anchor: .center)
    }
}
