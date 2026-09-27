import SwiftUI
import FITSCore
import TheiaKit

/// Compass (N + E arrows) and angular scale bar, drawn at fixed positions in view
/// space. Image-space sky directions are flipped vertically for Canvas coordinates.
public struct CompassScaleBarOverlay: View {
    public let wcs: WCS
    public let viewport: ImageViewState

    public init(wcs: WCS, viewport: ImageViewState) {
        self.wcs = wcs
        self.viewport = viewport
    }

    public var body: some View {
        let viewportScale = viewport.transform.scale
        Canvas { context, size in
            let primitives = OverlayScene.compassAndScaleBar(
                wcs: wcs,
                viewSize: SIMD2(Double(size.width), Double(size.height)),
                viewportScale: viewportScale
            )
            OverlayCanvas.draw(primitives, in: context)
        }
        .allowsHitTesting(false)
    }
}
