import Foundation
import FITSCore
import FITSRaster

public enum ExportFormat {
    case png
    case tiff
}

/// Mac file service around the portable native-resolution raster and encoders.
public enum ImageExport {
    public static func render(
        _ image: FITSImage,
        stretch: ImageStretch,
        vmin: Double,
        vmax: Double,
        colorMap: ColorMap = .gray,
        parameter: Float = 2
    ) -> [UInt8] {
        let display = DisplayImage(image: image, revision: 0)
        return ViewportRasterizer.renderNative(
            display, stretch: stretch,
            levels: RasterLevels(vmin: Float(vmin), vmax: Float(vmax)),
            colorMap: colorMap, parameter: parameter
        ).bytes
    }

    public static func writeImage(
        _ image: FITSImage,
        stretch: ImageStretch,
        vmin: Double,
        vmax: Double,
        colorMap: ColorMap = .gray,
        parameter: Float = 2,
        format: ExportFormat,
        to url: URL
    ) throws {
        let display = DisplayImage(image: image, revision: 0)
        let raster = ViewportRasterizer.renderNative(
            display, stretch: stretch,
            levels: RasterLevels(vmin: Float(vmin), vmax: Float(vmax)),
            colorMap: colorMap, parameter: parameter
        )
        let data: Data
        switch format {
        case .png: data = try RasterEncoder.png(raster)
        case .tiff: data = try RasterEncoder.tiff(raster)
        }
        try data.write(to: url)
    }

    public static func writeImage(
        _ image: FITSImage,
        stretch: ImageStretch,
        colorMap: ColorMap = .gray,
        parameter: Float = 2,
        format: ExportFormat,
        to url: URL
    ) throws {
        let range = image.defaultRange()
        try writeImage(
            image, stretch: stretch, vmin: range?.z1 ?? 0, vmax: range?.z2 ?? 1,
            colorMap: colorMap, parameter: parameter, format: format, to: url
        )
    }
}
