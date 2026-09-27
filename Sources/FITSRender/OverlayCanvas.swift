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
            case .text(let text, let at, let stroke, let size, let opacity,
                       let font, let anchor, let background):
                let nativeFont: NSFont
                switch font {
                case .monospaced: nativeFont = .monospacedSystemFont(ofSize: size, weight: .regular)
                case .systemSemibold: nativeFont = .systemFont(ofSize: size, weight: .semibold)
                case .systemMedium: nativeFont = .systemFont(ofSize: size, weight: .medium)
                }
                let attr = AttributedString(text, attributes: AttributeContainer([
                    .foregroundColor: NSColor(cgColor: NSColor(color(stroke).opacity(opacity)).cgColor) ?? .green,
                    .font: nativeFont,
                ]))
                let resolved = context.resolve(Text(attr))
                let unitAnchor: UnitPoint
                switch anchor {
                case .center: unitAnchor = .center
                case .topTrailing: unitAnchor = .topTrailing
                case .trailing: unitAnchor = .trailing
                case .bottomTrailing: unitAnchor = .bottomTrailing
                }
                var textPoint = CGPoint(x: at.x, y: at.y)
                if let background {
                    let measured = resolved.measure(in: CGSize(width: CGFloat.infinity,
                                                               height: CGFloat.infinity))
                    let paddedWidth = measured.width + 2 * background.horizontalPadding
                    let paddedHeight = measured.height + 2 * background.verticalPadding
                    let left: Double
                    let top: Double
                    switch anchor {
                    case .center:
                        left = at.x - paddedWidth / 2
                        top = at.y - paddedHeight / 2
                    case .topTrailing:
                        left = at.x - paddedWidth
                        top = at.y
                    case .trailing:
                        left = at.x - paddedWidth
                        top = at.y - paddedHeight / 2
                    case .bottomTrailing:
                        left = at.x - paddedWidth
                        top = at.y - paddedHeight
                    }
                    let rect = CGRect(x: left, y: top,
                                      width: paddedWidth, height: paddedHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: background.cornerRadius),
                                 with: .color(color(background.color).opacity(background.opacity)))
                    switch anchor {
                    case .center: break
                    case .topTrailing: textPoint = CGPoint(x: at.x - background.horizontalPadding,
                                                           y: at.y + background.verticalPadding)
                    case .trailing: textPoint.x -= background.horizontalPadding
                    case .bottomTrailing: textPoint = CGPoint(x: at.x - background.horizontalPadding,
                                                              y: at.y - background.verticalPadding)
                    }
                }
                context.draw(resolved, at: textPoint, anchor: unitAnchor)
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
