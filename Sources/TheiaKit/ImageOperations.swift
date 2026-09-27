import FITSCore

public enum ImageOperations {
    /// Combine same-size displayed images on the reference document's pixel grid.
    public static func stack(_ images: [FITSImage], referenceWCS: WCS?,
                             mode: StackMode) -> DerivedImage? {
        guard images.count >= 2, let first = images.first,
              images.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            return nil
        }
        let width = first.width, height = first.height
        var pixels = [Float](repeating: 0, count: width * height)
        for index in pixels.indices {
            let x = index % width, y = index / width
            var values: [Double] = []
            values.reserveCapacity(images.count)
            for image in images {
                let value = image.physicalValue(x: x, y: y)
                if !value.isNaN { values.append(value) }
            }
            guard !values.isEmpty else { pixels[index] = .nan; continue }
            switch mode {
            case .sum: pixels[index] = Float(values.reduce(0, +))
            case .mean: pixels[index] = Float(values.reduce(0, +) / Double(values.count))
            case .median:
                values.sort()
                pixels[index] = Float(values[values.count / 2])
            }
        }
        return DerivedImage(
            image: FITSImage.fromFloat32(pixels: pixels, width: width, height: height),
            wcs: referenceWCS,
            label: "Stack \(mode.label) of \(images.count) windows"
        )
    }

    /// Average complete factor-by-factor blocks of the displayed image.
    public static func bin(_ image: FITSImage, wcs: WCS?, factor: Int) -> DerivedImage? {
        guard factor >= 2, factor <= image.width, factor <= image.height else { return nil }
        let outputWCS: WCS?
        if let wcs {
            guard let transformed = wcs.binned(by: factor) else { return nil }
            outputWCS = transformed
        } else {
            outputWCS = nil
        }
        let width = image.width / factor
        let height = image.height / factor
        guard width > 0, height > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height)
        for blockY in 0..<height {
            for blockX in 0..<width {
                var sum = 0.0
                var count = 0
                for offsetY in 0..<factor {
                    for offsetX in 0..<factor {
                        let value = image.physicalValue(
                            x: blockX * factor + offsetX,
                            y: blockY * factor + offsetY
                        )
                        if !value.isNaN { sum += value; count += 1 }
                    }
                }
                pixels[blockY * width + blockX] = count > 0 ? Float(sum / Double(count)) : .nan
            }
        }
        return DerivedImage(
            image: FITSImage.fromFloat32(pixels: pixels, width: width, height: height),
            wcs: outputWCS, label: "Binned \(factor)×\(factor)"
        )
    }

    /// Copy a zero-based image rectangle, keeping its WCS origin aligned.
    public static func crop(_ image: FITSImage, wcs: WCS?, originX: Int, originY: Int,
                            width: Int, height: Int) -> DerivedImage? {
        guard originX >= 0, originY >= 0, width > 0, height > 0,
              width <= image.width, height <= image.height,
              originX <= image.width - width,
              originY <= image.height - height else { return nil }
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = Float(image.physicalValue(x: originX + x,
                                                                   y: originY + y))
            }
        }
        let maxX = originX + width - 1
        let maxY = originY + height - 1
        return DerivedImage(
            image: FITSImage.fromFloat32(pixels: pixels, width: width, height: height),
            wcs: wcs?.cropped(originX: originX, originY: originY),
            label: "Crop \(originX),\(originY) → \(maxX),\(maxY)"
        )
    }
}
