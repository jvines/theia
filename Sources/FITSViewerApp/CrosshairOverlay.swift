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
            let mapping = ViewMapping(
                transform: transform,
                viewSize: SIMD2(Double(size.width), Double(size.height)),
                backingScale: 1
            )
            OverlayCanvas.draw(OverlayScene.crosshair(at: imagePoint, mapping: mapping), in: ctx)
        }
        .allowsHitTesting(false)
    }
}
