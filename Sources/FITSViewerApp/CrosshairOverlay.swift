import SwiftUI
import FITSCore
import FITSRender
import TheiaKit

/// Draws a small targeting crosshair at the given image-pixel coordinate. Used by
/// the cross-window crosshair sync feature so hovering window A drops a marker at
/// the matching sky position in window B.
struct CrosshairOverlay: View {
    let imagePoint: SIMD2<Double>?
    let viewport: ImageViewState

    var body: some View {
        let transform = viewport.transform
        Canvas { ctx, size in
            guard let p = imagePoint else { return }
            let mapping = ViewMapping(
                transform: transform,
                viewSize: SIMD2(Double(size.width), Double(size.height)),
                backingScale: 1
            )
            let point = mapping.imageToView(p)
            let cx = point.x
            let cy = point.y
            let r: Double = 14
            var path = Path()
            path.move(to: CGPoint(x: cx - r, y: cy))
            path.addLine(to: CGPoint(x: cx + r, y: cy))
            path.move(to: CGPoint(x: cx, y: cy - r))
            path.addLine(to: CGPoint(x: cx, y: cy + r))
            ctx.stroke(path, with: .color(.yellow.opacity(0.85)), lineWidth: 1.2)
            // Small open circle in the middle so the centre is clearly visible.
            let dotR: Double = 3
            let dot = Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
            ctx.stroke(dot, with: .color(.yellow.opacity(0.85)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
