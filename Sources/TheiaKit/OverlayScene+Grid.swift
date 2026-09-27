import FITSCore

extension OverlayScene {
    /// Map cached image-space grid geometry through the current view transform.
    nonisolated public static func gridPrimitives(_ lines: [WCSGridline],
                                                   mapping: ViewMapping) -> [OverlayPrimitive] {
        lines.map { line in
            let color = line.kind == .ra
                ? OverlayColor(red: 0, green: 1, blue: 0)
                : OverlayColor(red: 1, green: 1, blue: 0)
            return .path(points: line.pixelPoints.map(mapping.imageToView), closed: false,
                         stroke: color, opacity: 0.6, lineWidth: 0.7)
        }
    }
}
