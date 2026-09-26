import Dispatch
import Foundation
import FITSCore

/// Top-down RGBA8 rows, suitable for a viewport texture or image encoder.
public struct RasterImage: Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(width > 0 && height > 0 && width <= Int.max / 4 / height)
        precondition(bytes.count == width * height * 4)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public func pixel(x: Int, y: Int) -> RGBA8 {
        precondition((0..<width).contains(x) && (0..<height).contains(y))
        let offset = (y * width + x) * 4
        return RGBA8(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2], a: bytes[offset + 3])
    }
}

public enum ViewportRasterizer {
    /// Draws at device-pixel centres. `sampleStep` samples the centre of each
    /// block and reduces the output dimensions by the same factor.
    public static func renderViewport(
        _ display: DisplayImage,
        mapping: ViewMapping,
        width: Int,
        height: Int,
        sampleStep: Int = 1,
        stretch: ImageStretch,
        levels: RasterLevels,
        colorMap: ColorMap,
        parameter: Float = 2,
        background: RGBA8 = .opaqueBlack
    ) -> RasterImage {
        precondition(width > 0 && height > 0 && sampleStep > 0)
        precondition(mapping.transform.scale > 0 && mapping.backingScale > 0)
        let outputWidth = 1 + (width - 1) / sampleStep
        let outputHeight = 1 + (height - 1) / sampleStep
        precondition(outputWidth <= Int.max / 4 / outputHeight)
        let table = ColorTable.cached(colorMap)
        let cdf = stretch == .histogramEq
            ? RasterCDF.make(sortedFiniteSample: display.sortedFiniteSample, levels: levels)
            : nil

        let coordinates = RasterCoordinateMapping(mapping, sampleStep: sampleStep)
        var bytes = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let workers = min(outputHeight, ProcessInfo.processInfo.activeProcessorCount)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for row in stride(from: worker, to: outputHeight, by: workers) {
                    var imageY = coordinates.imageY(row: row)
                    let remainingRows = height - row * sampleStep
                    if remainingRows < sampleStep {
                        imageY -= Float(remainingRows - sampleStep) * 0.5 / (coordinates.backing * coordinates.scale)
                    }
                    for column in 0..<outputWidth {
                        var imageX = coordinates.imageX(column: column)
                        let remainingColumns = width - column * sampleStep
                        if remainingColumns < sampleStep {
                            imageX += Float(remainingColumns - sampleStep) * 0.5 / (coordinates.backing * coordinates.scale)
                        }
                        let color: RGBA8
                        if imageX.isFinite, imageY.isFinite,
                           imageX >= -0.5, imageY >= -0.5,
                           imageX < Float(display.width) - 0.5,
                           imageY < Float(display.height) - 0.5 {
                            let x = Int((imageX + 0.5).rounded(.down))
                            let y = Int((imageY + 0.5).rounded(.down))
                            let value = display.pixels[y * display.width + x]
                            let normalized = RasterStretch.apply(
                                value, stretch: stretch, levels: levels, parameter: parameter, cdf: cdf
                            )
                            color = table.color(for: normalized)
                        } else {
                            color = background
                        }
                        let offset = (row * outputWidth + column) * 4
                        base[offset] = color.r
                        base[offset + 1] = color.g
                        base[offset + 2] = color.b
                        base[offset + 3] = color.a
                    }
                }
            }
        }
        return RasterImage(width: outputWidth, height: outputHeight, bytes: bytes)
    }

    /// One output pixel per image pixel. Top-down output places FITS (1, 1)
    /// at the bottom left after encoding.
    public static func renderNative(
        _ display: DisplayImage,
        stretch: ImageStretch,
        levels: RasterLevels,
        colorMap: ColorMap,
        parameter: Float = 2
    ) -> RasterImage {
        let mapping = ViewMapping(
            transform: ViewTransform(
                scale: 1,
                centre: SIMD2(Double(display.width - 1) / 2, Double(display.height - 1) / 2)
            ),
            viewSize: SIMD2(Double(display.width), Double(display.height)),
            backingScale: 1
        )
        return renderViewport(
            display, mapping: mapping, width: display.width, height: display.height,
            stretch: stretch, levels: levels, colorMap: colorMap, parameter: parameter
        )
    }
}
