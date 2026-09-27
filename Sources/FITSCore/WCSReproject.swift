import Foundation

public enum WCSReproject {
    /// Resamples `source` (with `sourceWCS`) onto a new grid defined by `targetWCS` and
    /// `(targetWidth, targetHeight)` via bilinear interpolation. Target pixels whose
    /// sky position falls outside the source footprint become NaN. NaN in the source
    /// propagates to the target.
    public static func reproject(
        source: FITSImage,
        sourceWCS: WCS,
        targetWCS: WCS,
        targetWidth: Int,
        targetHeight: Int
    ) -> FITSImage {
        let sourcePixels = source.normalizedFloat32()
        let sw = source.width, sh = source.height
        var out = [Float](repeating: .nan, count: targetWidth * targetHeight)
        for ty in 0..<targetHeight {
            for tx in 0..<targetWidth {
                guard let sky = targetWCS.pixelToSky(imageX: tx, imageY: ty) else {
                    continue
                }
                let sourceSky = CelestialTransform.convert(
                    lon: sky.ra, lat: sky.dec,
                    from: targetWCS.nativeFrame, to: sourceWCS.nativeFrame
                )
                guard let src = sourceWCS.skyToPixel(
                    ra: sourceSky.lon, dec: sourceSky.lat
                ) else { continue }
                out[ty * targetWidth + tx] = bilinear(
                    pixels: sourcePixels, width: sw, height: sh,
                    x: src.x, y: src.y
                )
            }
        }
        return FITSImage.fromFloat32(pixels: out, width: targetWidth, height: targetHeight)
    }

    /// NaN-aware bilinear sample. Returns NaN for out-of-bounds or NaN neighbors. A
    /// small tolerance lets round-trip floating-point errors at the image boundary
    /// still resolve to a valid edge pixel.
    private static func bilinear(
        pixels: [Float], width: Int, height: Int, x: Double, y: Double
    ) -> Float {
        let eps = 1e-6
        let maxX = Double(width - 1)
        let maxY = Double(height - 1)
        if x < -eps || y < -eps || x > maxX + eps || y > maxY + eps { return .nan }
        let xc = min(maxX, max(0, x))
        let yc = min(maxY, max(0, y))
        let x0 = Int(xc.rounded(.down))
        let y0 = Int(yc.rounded(.down))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = Float(xc - Double(x0))
        let fy = Float(yc - Double(y0))
        let v00 = pixels[y0 * width + x0]
        let v10 = pixels[y0 * width + x1]
        let v01 = pixels[y1 * width + x0]
        let v11 = pixels[y1 * width + x1]
        if v00.isNaN || v01.isNaN || v10.isNaN || v11.isNaN { return .nan }
        let top = v00 * (1 - fx) + v10 * fx
        let bot = v01 * (1 - fx) + v11 * fx
        return top * (1 - fy) + bot * fy
    }
}
