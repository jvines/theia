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
            for primitive in primitives {
                draw(primitive, in: context)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ primitive: OverlayPrimitive, in context: GraphicsContext) {
        switch primitive {
        case .path(let points, let closed, let stroke, let opacity, let lineWidth):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            if closed { path.closeSubpath() }
            context.stroke(path, with: .color(color(stroke).opacity(opacity)), lineWidth: lineWidth)
        case .ellipse(let center, let radiusX, let radiusY, let stroke, let opacity, let lineWidth):
            var path = Path()
            path.addEllipse(in: CGRect(x: center.x - radiusX, y: center.y - radiusY,
                                       width: radiusX * 2, height: radiusY * 2))
            context.stroke(path, with: .color(color(stroke).opacity(opacity)), lineWidth: lineWidth)
        case .text(let text, let at, let stroke, let size, let opacity):
            let attr = AttributedString(text, attributes: AttributeContainer([
                .foregroundColor: NSColor(cgColor: NSColor(color(stroke).opacity(opacity)).cgColor) ?? .green,
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            ]))
            context.draw(Text(attr), at: CGPoint(x: at.x, y: at.y), anchor: .center)
        case .handle(let center, let radius, let fill):
            var path = Path()
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
            context.fill(path, with: .color(color(fill)))
        }
    }

    private func color(_ rgb: OverlayColor) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
