import SwiftUI
import TheiaKit

/// Draws platform-neutral overlay primitives with SwiftUI Canvas.
public enum OverlayCanvas {
    public static func draw(_ primitives: [OverlayPrimitive], in context: GraphicsContext) {
        for primitive in primitives {
            switch primitive {
            case .path(let points, let closed, let stroke, let opacity, let lineWidth):
                guard let first = points.first else { continue }
                var path = Path()
                path.move(to: CGPoint(x: first.x, y: first.y))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x, y: point.y))
                }
                if closed { path.closeSubpath() }
                context.stroke(path, with: .color(color(stroke).opacity(opacity)), lineWidth: lineWidth)
            case .segments(let lines, let stroke, let opacity, let lineWidth, let dash):
                var path = Path()
                for line in lines {
                    path.move(to: CGPoint(x: line.from.x, y: line.from.y))
                    path.addLine(to: CGPoint(x: line.to.x, y: line.to.y))
                }
                context.stroke(path, with: .color(color(stroke).opacity(opacity)),
                               style: StrokeStyle(lineWidth: lineWidth, dash: dash.map { CGFloat($0) }))
            case .ellipse(let center, let radiusX, let radiusY, let stroke, let opacity, let lineWidth, let dash):
                var path = Path()
                path.addEllipse(in: CGRect(x: center.x - radiusX, y: center.y - radiusY,
                                           width: radiusX * 2, height: radiusY * 2))
                context.stroke(path, with: .color(color(stroke).opacity(opacity)),
                               style: StrokeStyle(lineWidth: lineWidth, dash: dash.map { CGFloat($0) }))
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
    }

    private static func color(_ rgb: OverlayColor) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
