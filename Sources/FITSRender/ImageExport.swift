import Foundation
import AppKit
import FITSCore

public enum ExportFormat {
    case png
    case tiff
}

public enum ExportError: Error {
    case bitmapRepCreationFailed
    case encodingFailed
}

public enum ImageExport {
    /// Renders the image at full resolution into row-major RGBA8 bytes,
    /// applying the chosen stretch over `[vmin, vmax]`. NaN pixels (BLANK / float NaN)
    /// render as opaque black, matching the on-screen shader.
    public static func render(
        _ image: FITSImage,
        stretch: ImageStretch,
        vmin: Double,
        vmax: Double,
        cdf: [Double]? = nil
    ) -> [UInt8] {
        let w = image.width
        let h = image.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = image.physicalValue(x: x, y: y)
                let stretched = stretch.apply(v, vmin: vmin, vmax: vmax, cdf: cdf)
                let gray: UInt8
                if stretched.isNaN {
                    gray = 0
                } else {
                    let clamped = max(0.0, min(1.0, stretched))
                    gray = UInt8((clamped * 255).rounded())
                }
                let i = (y * w + x) * 4
                out[i] = gray
                out[i + 1] = gray
                out[i + 2] = gray
                out[i + 3] = 255
            }
        }
        return out
    }

    public static func writeImage(
        _ image: FITSImage,
        stretch: ImageStretch,
        vmin: Double,
        vmax: Double,
        cdf: [Double]? = nil,
        format: ExportFormat,
        to url: URL
    ) throws {
        let bytes = render(image, stretch: stretch, vmin: vmin, vmax: vmax, cdf: cdf)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: image.width,
            pixelsHigh: image.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: image.width * 4,
            bitsPerPixel: 32
        ), let dest = rep.bitmapData else {
            throw ExportError.bitmapRepCreationFailed
        }
        memcpy(dest, bytes, bytes.count)
        let fileType: NSBitmapImageRep.FileType
        switch format {
        case .png: fileType = .png
        case .tiff: fileType = .tiff
        }
        guard let data = rep.representation(using: fileType, properties: [:]) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url)
    }

    /// Convenience that derives `vmin/vmax` from `image.defaultRange()` and computes the
    /// CDF on demand for `.histogramEq`.
    public static func writeImage(
        _ image: FITSImage,
        stretch: ImageStretch,
        format: ExportFormat,
        to url: URL
    ) throws {
        let range = image.defaultRange()
        let vmin = range?.z1 ?? 0
        let vmax = range?.z2 ?? 1
        var cdf: [Double]? = nil
        if stretch == .histogramEq {
            let values = image.physicalValues()
            if let mm = PixelStatistics.minMax(values), mm.max > mm.min {
                cdf = PixelStatistics.histogram(values, bins: 256, range: mm.min...mm.max).cdf()
            }
        }
        try writeImage(image, stretch: stretch, vmin: vmin, vmax: vmax, cdf: cdf, format: format, to: url)
    }
}
