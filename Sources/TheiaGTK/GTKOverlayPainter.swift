import CGtk4
import Foundation
import TheiaKit

/// Cairo adapter for the platform-neutral overlay geometry used by the Mac canvas.
enum GTKOverlayPainter {
    static func draw(_ primitives: [OverlayPrimitive], in context: OpaquePointer) {
        for primitive in primitives {
            cairo_save(context)
            switch primitive {
            case .segments(let segments, let color, let opacity, let width, let dash):
                stroke(context, color: color, opacity: opacity, width: width, dash: dash) {
                    for segment in segments where finite(segment.from) && finite(segment.to) {
                        cairo_move_to(context, segment.from.x, segment.from.y)
                        cairo_line_to(context, segment.to.x, segment.to.y)
                    }
                }
            case .path(let points, let closed, let color, let opacity, let width):
                if let first = points.first, points.allSatisfy(finite) {
                    stroke(context, color: color, opacity: opacity, width: width, dash: []) {
                        cairo_move_to(context, first.x, first.y)
                        for point in points.dropFirst() { cairo_line_to(context, point.x, point.y) }
                        if closed { cairo_close_path(context) }
                    }
                }
            case .ellipse(let center, let radiusX, let radiusY, let color, let opacity,
                          let width, let dash):
                if finite(center), radiusX.isFinite, radiusY.isFinite,
                   radiusX > 0, radiusY > 0 {
                    stroke(context, color: color, opacity: opacity, width: width, dash: dash) {
                        cairo_save(context)
                        cairo_translate(context, center.x, center.y)
                        cairo_scale(context, radiusX, radiusY)
                        cairo_arc(context, 0, 0, 1, 0, 2 * .pi)
                        cairo_restore(context)
                    }
                }
            case .text(let value, let point, let color, let size, let opacity,
                       let font, let anchor, let background):
                drawText(value, at: point, color: color, size: size, opacity: opacity,
                         font: font, anchor: anchor, background: background, in: context)
            case .handle(let center, let radius, let color):
                if finite(center), radius.isFinite, radius > 0 {
                    setColor(color, opacity: 1, in: context)
                    cairo_arc(context, center.x, center.y, radius, 0, 2 * .pi)
                    cairo_fill(context)
                }
            }
            cairo_restore(context)
        }
    }

    private static func finite(_ point: SIMD2<Double>) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func setColor(_ color: OverlayColor, opacity: Double,
                                 in context: OpaquePointer) {
        cairo_set_source_rgba(context, color.red, color.green, color.blue,
                              min(1, max(0, opacity)))
    }

    private static func stroke(_ context: OpaquePointer, color: OverlayColor,
                               opacity: Double, width: Double, dash: [Double],
                               path: () -> Void) {
        guard width.isFinite, width > 0 else { return }
        setColor(color, opacity: opacity, in: context)
        cairo_set_line_width(context, width)
        dash.withUnsafeBufferPointer {
            cairo_set_dash(context, $0.baseAddress, Int32($0.count), 0)
        }
        path()
        cairo_stroke(context)
    }

    private static func drawText(_ value: String, at point: SIMD2<Double>,
                                 color: OverlayColor, size: Double, opacity: Double,
                                 font: OverlayFont, anchor: OverlayTextAnchor,
                                 background: OverlayTextBackground?,
                                 in context: OpaquePointer) {
        guard !value.isEmpty, finite(point), size.isFinite, size > 0 else { return }
        let family = font == .monospaced ? "monospace" : "sans"
        let weight = font == .monospaced ? CAIRO_FONT_WEIGHT_NORMAL : CAIRO_FONT_WEIGHT_BOLD
        cairo_select_font_face(context, family, CAIRO_FONT_SLANT_NORMAL, weight)
        cairo_set_font_size(context, size)
        var extents = cairo_text_extents_t()
        value.withCString { cairo_text_extents(context, $0, &extents) }
        let padX = background?.horizontalPadding ?? 0
        let padY = background?.verticalPadding ?? 0
        let outerWidth = extents.width + 2 * padX
        let outerHeight = extents.height + 2 * padY
        let left: Double
        let top: Double
        switch anchor {
        case .center:
            left = point.x - outerWidth / 2
            top = point.y - outerHeight / 2
        case .topTrailing:
            left = point.x - outerWidth
            top = point.y
        case .trailing:
            left = point.x - outerWidth
            top = point.y - outerHeight / 2
        case .bottomTrailing:
            left = point.x - outerWidth
            top = point.y - outerHeight
        }
        if let background {
            setColor(background.color, opacity: background.opacity, in: context)
            let radius = max(0, min(background.cornerRadius, outerWidth / 2, outerHeight / 2))
            cairo_new_sub_path(context)
            cairo_arc(context, left + outerWidth - radius, top + radius, radius, -.pi / 2, 0)
            cairo_arc(context, left + outerWidth - radius, top + outerHeight - radius,
                      radius, 0, .pi / 2)
            cairo_arc(context, left + radius, top + outerHeight - radius,
                      radius, .pi / 2, .pi)
            cairo_arc(context, left + radius, top + radius, radius, .pi, 3 * .pi / 2)
            cairo_close_path(context)
            cairo_fill(context)
        }
        setColor(color, opacity: opacity, in: context)
        cairo_move_to(context, left + padX - extents.x_bearing,
                      top + padY - extents.y_bearing)
        value.withCString { cairo_show_text(context, $0) }
    }
}
