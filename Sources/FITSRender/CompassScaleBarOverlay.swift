import SwiftUI
import simd
import FITSCore
import TheiaKit

/// Compass (N + E arrows) and angular scale bar, drawn at fixed positions in view
/// space. The compass uses image-space sky directions directly (no Y-flip) so it
/// stays consistent with the renderer's current image orientation.
public struct CompassScaleBarOverlay: View {
    public let wcs: WCS
    public let viewport: ImageViewState

    private let arrowLength: Double = 30
    private let scaleBarTargetPoints: Double = 100

    public init(wcs: WCS, viewport: ImageViewState) {
        self.wcs = wcs
        self.viewport = viewport
    }

    public var body: some View {
        let viewportScale = viewport.transform.scale
        Canvas { context, size in
            drawCompass(context: context)
            drawScaleBar(context: context, size: size, viewportScale: viewportScale)
        }
        .allowsHitTesting(false)
    }

    private func drawCompass(context: GraphicsContext) {
        let origin = CGPoint(x: 50, y: 50)
        let compass = wcs.compass
        // image-space y-up → canvas y-down: negate the y component for screen drawing.
        let eastDir = SIMD2(compass.eastDirectionImage.x, -compass.eastDirectionImage.y)
        let northDir = SIMD2(compass.northDirectionImage.x, -compass.northDirectionImage.y)

        let eastTip = CGPoint(
            x: origin.x + eastDir.x * arrowLength,
            y: origin.y + eastDir.y * arrowLength
        )
        let northTip = CGPoint(
            x: origin.x + northDir.x * arrowLength,
            y: origin.y + northDir.y * arrowLength
        )

        var line = Path()
        line.move(to: origin); line.addLine(to: eastTip)
        line.move(to: origin); line.addLine(to: northTip)
        context.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.5)

        let labelOffset = 10.0
        let eastLabel = CGPoint(
            x: eastTip.x + eastDir.x * labelOffset,
            y: eastTip.y + eastDir.y * labelOffset
        )
        let northLabel = CGPoint(
            x: northTip.x + northDir.x * labelOffset,
            y: northTip.y + northDir.y * labelOffset
        )
        context.draw(
            Text("E").font(.caption.weight(.semibold)).foregroundColor(.white),
            at: eastLabel
        )
        context.draw(
            Text("N").font(.caption.weight(.semibold)).foregroundColor(.white),
            at: northLabel
        )
    }

    private func drawScaleBar(context: GraphicsContext, size: CGSize, viewportScale: Double) {
        let pixelScale = wcs.pixelScaleArcsec
        guard let r = ScaleBar.niceAngularExtent(
            viewPointsTarget: scaleBarTargetPoints,
            pixelScaleArcsec: pixelScale,
            viewportScale: viewportScale
        ), r.lengthPoints.isFinite, r.lengthPoints > 0 else { return }

        let barY = size.height - 30
        let leftX = 30.0
        let rightX = leftX + r.lengthPoints

        var path = Path()
        path.move(to: CGPoint(x: leftX, y: barY))
        path.addLine(to: CGPoint(x: rightX, y: barY))
        path.move(to: CGPoint(x: leftX, y: barY - 5))
        path.addLine(to: CGPoint(x: leftX, y: barY + 5))
        path.move(to: CGPoint(x: rightX, y: barY - 5))
        path.addLine(to: CGPoint(x: rightX, y: barY + 5))
        context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)

        context.draw(
            Text(formatLength(r.lengthArcsec))
                .font(.caption.weight(.medium))
                .foregroundColor(.white),
            at: CGPoint(x: (leftX + rightX) / 2, y: barY - 14)
        )
    }

    private func formatLength(_ arcsec: Double) -> String {
        if arcsec >= 3600 { return String(format: "%g°", arcsec / 3600) }
        if arcsec >= 60   { return String(format: "%g'", arcsec / 60) }
        return String(format: "%g″", arcsec)
    }
}
