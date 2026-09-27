import SwiftUI
import FITSCore
import TheiaKit

/// SwiftUI overlay that draws `Region` annotations on top of a `FITSMetalView`.
/// Image-frame regions render directly; sky-frame regions resolve via the
/// supplied WCS (if any).
public struct RegionOverlay: View {
    public let regions: [Region]
    public let selectedIndex: Int?
    public let wcs: WCS?
    public let viewport: ImageViewState

    public init(regions: [Region], selectedIndex: Int? = nil, wcs: WCS?, viewport: ImageViewState) {
        self.regions = regions
        self.selectedIndex = selectedIndex
        self.wcs = wcs
        self.viewport = viewport
    }

    public var body: some View {
        let transform = viewport.transform
        Canvas { context, size in
            let mapping = ViewMapping(
                transform: transform,
                viewSize: SIMD2(Double(size.width), Double(size.height)),
                backingScale: 1
            )
            for (idx, region) in regions.enumerated() {
                guard let path = path(for: region, mapping: mapping) else { continue }
                let rgb = OverlayColor.parse(region.attributes["color"]) ?? .defaultRegion
                let colour = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                let isSelected = (idx == selectedIndex)
                let lineWidth: Double = isSelected ? 2.4 : 1.2
                let strokeColour = isSelected ? Color.yellow : colour.opacity(0.85)
                context.stroke(path, with: .color(strokeColour), lineWidth: lineWidth)
                // Text label: draw above the region's centre, if set.
                if let text = region.attributes["text"], !text.isEmpty,
                   let centre = labelAnchor(for: region, mapping: mapping) {
                    let attr = AttributedString(text, attributes: AttributeContainer([
                        .foregroundColor: NSColor(cgColor: NSColor(strokeColour).cgColor) ?? .green,
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    ]))
                    context.draw(Text(attr), at: CGPoint(x: centre.x, y: centre.y - 10), anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func labelAnchor(for region: Region, mapping: ViewMapping) -> CGPoint? {
        let p: Region.Point
        switch region.shape {
        case .circle(let c, _): p = c
        case .box(let c, _, _, _): p = c
        case .ellipse(let c, _, _, _): p = c
        case .annulus(let c, _, _): p = c
        case .point(let pt): p = pt
        case .polygon(let pts): guard let first = pts.first else { return nil }; p = first
        }
        guard let img = imagePixel(from: p, frame: region.frame) else { return nil }
        return canvasPoint(img, mapping)
    }

    /// Converts an image-space (y-up) point to canvas space (y-down).
    private func canvasPoint(_ image: (Double, Double), _ mapping: ViewMapping) -> CGPoint {
        let point = mapping.imageToView(SIMD2(image.0, image.1))
        return CGPoint(x: point.x, y: point.y)
    }

    private func path(for region: Region, mapping: ViewMapping) -> Path? {
        switch region.shape {
        case .circle(let center, let radius):
            guard let imageCentre = imagePixel(from: center, frame: region.frame),
                  let radiusPixels = pixelRadius(radius) else { return nil }
            let viewCentre = canvasPoint(imageCentre, mapping)
            let viewRadius = mapping.transform.scale * radiusPixels
            var path = Path()
            path.addEllipse(in: CGRect(
                x: viewCentre.x - viewRadius, y: viewCentre.y - viewRadius,
                width: viewRadius * 2, height: viewRadius * 2
            ))
            return path

        case .box(let center, let w, let h2, let angle):
            guard let imageCentre = imagePixel(from: center, frame: region.frame),
                  let wPix = pixelRadius(w),
                  let hPix = pixelRadius(h2) else { return nil }
            let viewCentre = canvasPoint(imageCentre, mapping)
            let halfW = mapping.transform.scale * wPix / 2
            let halfH = mapping.transform.scale * hPix / 2
            let corners = [
                CGPoint(x: -halfW, y: -halfH),
                CGPoint(x:  halfW, y: -halfH),
                CGPoint(x:  halfW, y:  halfH),
                CGPoint(x: -halfW, y:  halfH),
            ]
            // angles are degrees CCW in image space; canvas Y is flipped → invert.
            let theta = -angle * .pi / 180
            let cos = Foundation.cos(theta)
            let sin = Foundation.sin(theta)
            var path = Path()
            for (i, c) in corners.enumerated() {
                let p = CGPoint(
                    x: viewCentre.x + c.x * cos - c.y * sin,
                    y: viewCentre.y + c.x * sin + c.y * cos
                )
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path

        case .ellipse(let center, let rx, let ry, let angle):
            guard let imageCentre = imagePixel(from: center, frame: region.frame),
                  let rxPix = pixelRadius(rx),
                  let ryPix = pixelRadius(ry) else { return nil }
            let viewCentre = canvasPoint(imageCentre, mapping)
            let halfW = mapping.transform.scale * rxPix
            let halfH = mapping.transform.scale * ryPix
            let theta = -angle * .pi / 180
            var path = Path()
            // Approximate as 64-segment polygon, rotated.
            let steps = 64
            for i in 0...steps {
                let a = Double(i) / Double(steps) * 2 * .pi
                let lx = halfW * Foundation.cos(a)
                let ly = halfH * Foundation.sin(a)
                let p = CGPoint(
                    x: viewCentre.x + lx * Foundation.cos(theta) - ly * Foundation.sin(theta),
                    y: viewCentre.y + lx * Foundation.sin(theta) + ly * Foundation.cos(theta)
                )
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path

        case .annulus(let center, let rIn, let rOut):
            guard let imageCentre = imagePixel(from: center, frame: region.frame),
                  let innerPix = pixelRadius(rIn),
                  let outerPix = pixelRadius(rOut) else { return nil }
            let viewCentre = canvasPoint(imageCentre, mapping)
            let inner = mapping.transform.scale * innerPix
            let outer = mapping.transform.scale * outerPix
            var path = Path()
            path.addEllipse(in: CGRect(
                x: viewCentre.x - outer, y: viewCentre.y - outer,
                width: outer * 2, height: outer * 2
            ))
            path.addEllipse(in: CGRect(
                x: viewCentre.x - inner, y: viewCentre.y - inner,
                width: inner * 2, height: inner * 2
            ))
            return path

        case .polygon(let pts):
            var path = Path()
            for (i, dsPoint) in pts.enumerated() {
                guard let img = imagePixel(from: dsPoint, frame: region.frame) else { return nil }
                let p = canvasPoint(img, mapping)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path

        case .point(let p):
            guard let imageCentre = imagePixel(from: p, frame: region.frame) else { return nil }
            let viewCentre = canvasPoint(imageCentre, mapping)
            let r: Double = 3
            var path = Path()
            path.addEllipse(in: CGRect(
                x: viewCentre.x - r, y: viewCentre.y - r,
                width: r * 2, height: r * 2
            ))
            return path
        }
    }

    private func imagePixel(from point: Region.Point, frame: Region.Frame) -> (Double, Double)? {
        guard let pixel = imageCenter(of: point, frame: frame, wcs: wcs) else { return nil }
        return (pixel.x, pixel.y)
    }

    private func pixelRadius(_ d: Region.Distance) -> Double? {
        switch d.unit {
        case .pixel: return d.value
        case .arcsecond, .arcminute, .degree:
            guard let wcs else { return nil }
            let degrees: Double
            switch d.unit {
            case .arcsecond: degrees = d.value / 3600
            case .arcminute: degrees = d.value / 60
            case .degree: degrees = d.value
            case .pixel: degrees = 0
            }
            // Estimate the local pixel scale from the CD matrix determinant.
            let pixelScaleDegPerPix = sqrt(abs(wcs.cd11 * wcs.cd22 - wcs.cd12 * wcs.cd21))
            guard pixelScaleDegPerPix > 0 else { return nil }
            return degrees / pixelScaleDegPerPix
        }
    }
}
