import SwiftUI
import FITSCore
import TheiaKit

/// SwiftUI overlay that draws WCS RA/Dec gridlines on top of a `FITSMetalView`,
/// using the shared `ImageViewState` so panning and zooming stay in sync.
public struct WCSGridOverlay: View {
    public let image: FITSImage
    public let wcs: WCS
    public let viewport: ImageViewState
    @State private var gridCache = WCSGridCache()

    public init(image: FITSImage, wcs: WCS, viewport: ImageViewState) {
        self.image = image
        self.wcs = wcs
        self.viewport = viewport
    }

    public var body: some View {
        let transform = viewport.transform
        let lines = gridCache.gridlines(wcs: wcs, imageWidth: image.width, imageHeight: image.height)
        Canvas { context, size in
            let mapping = ViewMapping(
                transform: transform,
                viewSize: SIMD2(Double(size.width), Double(size.height)),
                backingScale: 1
            )
            for line in lines {
                var path = Path()
                var started = false
                for p in line.pixelPoints {
                    let mapped = mapping.imageToView(SIMD2(p.x, p.y))
                    let view = CGPoint(x: mapped.x, y: mapped.y)
                    if !started {
                        path.move(to: view)
                        started = true
                    } else {
                        path.addLine(to: view)
                    }
                }
                let colour: Color = line.kind == .ra ? .green : .yellow
                context.stroke(path, with: .color(colour.opacity(0.6)), lineWidth: 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}
