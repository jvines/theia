import Foundation
import FITSCore

public struct PixelTableCell: Sendable {
    public let x: Int
    public let y: Int
    public let value: Double
    public let isActive: Bool

    public var text: String {
        value.isNaN ? "—" : String(format: "%.3g", value)
    }
}

public struct PixelTableSnapshot: Sendable {
    public let rows: [[PixelTableCell]]
    public let coordinateText: String
    public let valueText: String
}

/// Values and coordinate labels for the pixel grid around a cursor position.
public struct PixelTableModel: Sendable {
    public static let sizes = [5, 7, 9, 11]
    public let size: Int

    public init(size: Int) {
        self.size = Self.sizes.contains(size) ? size : 7
    }

    public func snapshot(image: FITSImage?, cursor: CursorInfo?) -> PixelTableSnapshot? {
        guard let image, let cursor else { return nil }
        let half = size / 2
        let rows = (0..<size).map { row in
            (0..<size).map { column in
                let x = cursor.imageX - half + column
                let y = cursor.imageY + half - row
                let value = x >= 0 && x < image.width && y >= 0 && y < image.height
                    ? image.physicalValue(x: x, y: y) : Double.nan
                return PixelTableCell(x: x, y: y, value: value,
                                      isActive: row == half && column == half)
            }
        }
        return PixelTableSnapshot(
            rows: rows,
            coordinateText: "(x, y) = (\(cursor.fitsX), \(cursor.fitsY))",
            valueText: "value = \(rows[half][half].value.isNaN ? "NaN" : String(format: "%.6g", rows[half][half].value))"
        )
    }
}
