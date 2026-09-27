import Foundation
import FITSCore

public struct ColorBarLabels: Sendable, Equatable {
    public let top: String
    public let middle: String
    public let bottom: String

    public init(top: String, middle: String, bottom: String) {
        self.top = top
        self.middle = middle
        self.bottom = bottom
    }
}

extension OverlayScene {
    /// Compass and scale bar positions are fixed in view points.
    nonisolated public static func compassAndScaleBar(
        wcs: WCS, viewSize: SIMD2<Double>, viewportScale: Double
    ) -> [OverlayPrimitive] {
        let white = OverlayColor(red: 1, green: 1, blue: 1)
        let origin = SIMD2<Double>(50, 50)
        let compass = wcs.compass
        let east = SIMD2(compass.eastDirectionImage.x, -compass.eastDirectionImage.y)
        let north = SIMD2(compass.northDirectionImage.x, -compass.northDirectionImage.y)
        let eastTip = origin + east * 30
        let northTip = origin + north * 30
        var primitives: [OverlayPrimitive] = [
            .segments([.init(from: origin, to: eastTip),
                       .init(from: origin, to: northTip)],
                      stroke: white, opacity: 0.9, lineWidth: 1.5, dash: []),
            .text("E", at: eastTip + east * 10, color: white,
                  size: 12, opacity: 1, font: .systemSemibold),
            .text("N", at: northTip + north * 10, color: white,
                  size: 12, opacity: 1, font: .systemSemibold),
        ]

        guard let bar = ScaleBar.niceAngularExtent(
            viewPointsTarget: 100, pixelScaleArcsec: wcs.pixelScaleArcsec,
            viewportScale: viewportScale
        ), bar.lengthPoints.isFinite, bar.lengthPoints > 0 else { return primitives }
        let y = viewSize.y - 30
        let left = 30.0
        let right = left + bar.lengthPoints
        primitives.append(.segments([
            .init(from: SIMD2(left, y), to: SIMD2(right, y)),
            .init(from: SIMD2(left, y - 5), to: SIMD2(left, y + 5)),
            .init(from: SIMD2(right, y - 5), to: SIMD2(right, y + 5)),
        ], stroke: white, opacity: 0.9, lineWidth: 1.5, dash: []))
        primitives.append(.text(formatLength(bar.lengthArcsec),
                                at: SIMD2((left + right) / 2, y - 14),
                                color: white, size: 12, opacity: 1, font: .systemMedium))
        return primitives
    }

    nonisolated public static func colorBarLabels(vmin: Double, vmax: Double) -> ColorBarLabels {
        ColorBarLabels(top: formatLevel(vmax), middle: formatLevel((vmin + vmax) / 2),
                       bottom: formatLevel(vmin))
    }

    /// The enclosing view reserves a label column to the left of the color swatch.
    nonisolated public static func colorBarLabelPrimitives(
        vmin: Double, vmax: Double, labelSize: SIMD2<Double>
    ) -> [OverlayPrimitive] {
        let labels = colorBarLabels(vmin: vmin, vmax: vmax)
        let white = OverlayColor(red: 1, green: 1, blue: 1)
        let background = OverlayTextBackground(
            color: .init(red: 0, green: 0, blue: 0), opacity: 0.55,
            cornerRadius: 3, horizontalPadding: 4, verticalPadding: 1
        )
        return [
            .text(labels.top, at: SIMD2(labelSize.x, 0), color: white, size: 11,
                  opacity: 1, anchor: .topTrailing, background: background),
            .text(labels.middle, at: SIMD2(labelSize.x, labelSize.y / 2), color: white,
                  size: 11, opacity: 1, anchor: .trailing, background: background),
            .text(labels.bottom, at: labelSize, color: white, size: 11,
                  opacity: 1, anchor: .bottomTrailing, background: background),
        ]
    }

    nonisolated private static func formatLength(_ arcsec: Double) -> String {
        if arcsec >= 3600 { return String(format: "%g°", arcsec / 3600) }
        if arcsec >= 60 { return String(format: "%g'", arcsec / 60) }
        return String(format: "%g″", arcsec)
    }

    nonisolated private static func formatLevel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let magnitude = abs(value)
        if magnitude == 0 { return "0" }
        if magnitude >= 1e4 || magnitude < 0.01 { return String(format: "%.2e", value) }
        return String(format: "%.3g", value)
    }
}
