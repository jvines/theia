import SwiftUI
import FITSRender
import TheiaKit

/// Draws the most recent profile request or its drag preview.
struct ProfileGeometryOverlay: View {
    let geometry: ProfileGeometry?
    let viewport: ImageViewState

    var body: some View {
        let transform = viewport.transform
        Canvas { context, size in
            let mapping = ViewMapping(transform: transform,
                                      viewSize: SIMD2(Double(size.width), Double(size.height)),
                                      backingScale: 1)
            OverlayCanvas.draw(OverlayScene.profile(geometry, mapping: mapping), in: context)
        }
        .allowsHitTesting(false)
    }
}
