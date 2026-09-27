import SwiftUI
import FITSCore
import TheiaKit

/// Mac drawing adapter for image-space region geometry from `OverlayScene`.
public struct RegionOverlay: View {
    public let regions: [Region]
    public let selectedIndex: Int?
    public let previewRegion: Region?
    public let wcs: WCS?
    public let viewport: ImageViewState
    @State private var scene = OverlayScene()

    public init(regions: [Region], selectedIndex: Int? = nil,
                previewRegion: Region? = nil, wcs: WCS?, viewport: ImageViewState) {
        self.regions = regions
        self.selectedIndex = selectedIndex
        self.previewRegion = previewRegion
        self.wcs = wcs
        self.viewport = viewport
    }

    public var body: some View {
        let transform = viewport.transform
        Canvas { context, size in
            let mapping = ViewMapping(transform: transform,
                                      viewSize: SIMD2(Double(size.width), Double(size.height)),
                                      backingScale: 1)
            let primitives = scene.regionPrimitives(regions, selectedIndex: selectedIndex,
                                                    preview: previewRegion, wcs: wcs, mapping: mapping)
            OverlayCanvas.draw(primitives, in: context)
        }
        .allowsHitTesting(false)
    }
}
