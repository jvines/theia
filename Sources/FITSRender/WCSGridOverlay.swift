import SwiftUI
import FITSCore

/// SwiftUI overlay that draws WCS RA/Dec gridlines on top of a `FITSMetalView`,
/// using the shared `ViewportObservable` so panning and zooming stay in sync.
public struct WCSGridOverlay: View {
    public let image: FITSImage
    public let wcs: WCS
    @ObservedObject public var viewport: ViewportObservable

    public init(image: FITSImage, wcs: WCS, viewport: ViewportObservable) {
        self.image = image
        self.wcs = wcs
        self.viewport = viewport
    }

    public var body: some View {
        Canvas { context, size in
            let lines = WCSGridGenerator.gridlines(
                wcs: wcs,
                imageWidth: image.width,
                imageHeight: image.height
            )
            let t = viewport.transform
            for line in lines {
                var path = Path()
                var started = false
                for p in line.pixelPoints {
                    // image-space (y-up) → view-space (y-up) → canvas (y-down)
                    let view = CGPoint(
                        x: t.scale * p.x + t.translation.x,
                        y: size.height - (t.scale * p.y + t.translation.y)
                    )
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
