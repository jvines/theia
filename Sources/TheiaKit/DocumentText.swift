import Foundation
import FITSCore

/// Text shared by document chrome on Mac and the future Linux shell.
public enum DocumentText {
    public static func hduLabel(index: Int, name: String?) -> String {
        if let name { return "HDU \(index) — \(name)" }
        return "HDU \(index)"
    }

    public static func sidebarDetails(for hdu: FITSHDU) -> String {
        "\(hdu.kindLabel) · \(hdu.shapeDescription) · \(hdu.bitpixLabel)"
    }

    public static func statusDetails(for hdu: FITSHDU) -> String {
        "\(hdu.shapeDescription) · \(hdu.bitpixLabel)"
    }

    public static func windowSubtitle(for file: FITSFile) -> String {
        let count = file.hdus.count
        var parts = ["\(count) HDU\(count == 1 ? "" : "s")"]
        if let image = file.hdus.first(where: { $0.isImage && $0.naxis >= 2 }) {
            parts.append(image.shapeDescription)
            parts.append(image.bitpixLabel)
        }
        return parts.joined(separator: " · ")
    }

    public static func pixelCoordinates(imageX: Int, imageY: Int) -> String {
        "(\(imageX + 1), \(imageY + 1))"
    }

    public static func pixelValue(_ value: Double) -> String {
        value.isNaN ? "NaN" : String(format: "%.4g", value)
    }

    public static func level(_ value: Float) -> String {
        String(format: abs(value) < 1000 && abs(value) >= 0.01 ? "%.3g" : "%.2e", value)
    }
}
