import Foundation
import FITSCore

public enum ImageOperations {
    private static let maximumFilterSize = 101
    private static let maximumGaussianSigma = 32.0

    public static func validFilter(_ spec: FilterSpec) -> Bool {
        switch spec {
        case .boxcar(let size), .median(let size):
            return size > 0 && size <= maximumFilterSize && size % 2 == 1
        case .gaussian(let sigma):
            return sigma.isFinite && sigma > 0 && sigma <= maximumGaussianSigma
        }
    }

    /// Apply a filter to the displayed pixels without changing their sky grid.
    public static func filter(_ image: FITSImage, wcs: WCS?,
                              spec: FilterSpec) -> DerivedImage? {
        try! filterCheckingCancellation(image, wcs: wcs, spec: spec,
                                        checkCancellation: {})
    }

    public static func filterCheckingCancellation(
        _ image: FITSImage, wcs: WCS?, spec: FilterSpec,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage? {
        guard validFilter(spec) else { return nil }
        let filtered: FITSImage
        let label: String
        switch spec {
        case .boxcar(let size):
            filtered = try ImageFilters.boxcarCheckingCancellation(
                image, size: size, checkCancellation: checkCancellation)
            label = "Boxcar \(size)×\(size)"
        case .median(let size):
            filtered = try ImageFilters.medianCheckingCancellation(
                image, size: size, checkCancellation: checkCancellation)
            label = "Median \(size)×\(size)"
        case .gaussian(let sigma):
            filtered = try ImageFilters.gaussianCheckingCancellation(
                image, sigma: sigma, checkCancellation: checkCancellation)
            label = String(format: "Gaussian σ=%.1f", sigma)
        }
        return DerivedImage(image: filtered, wcs: wcs, label: label)
    }

    public static func unary(_ image: FITSImage, wcs: WCS?,
                             op: ImageArithmetic.UnaryOp) -> DerivedImage {
        try! unaryCheckingCancellation(image, wcs: wcs, op: op,
                                       checkCancellation: {})
    }

    public static func unaryCheckingCancellation(
        _ image: FITSImage, wcs: WCS?, op: ImageArithmetic.UnaryOp,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage {
        DerivedImage(image: try ImageArithmetic.unaryCheckingCancellation(
            image, op: op, checkCancellation: checkCancellation),
            wcs: wcs, label: op.label)
    }

    public static func binary(_ image: FITSImage, wcs: WCS?, other: FITSImage,
                              op: ImageArithmetic.BinaryOp, otherHDU: Int) throws -> DerivedImage {
        try binaryCheckingCancellation(image, wcs: wcs, other: other,
                                       op: op, otherHDU: otherHDU,
                                       checkCancellation: {})
    }

    public static func binaryCheckingCancellation(
        _ image: FITSImage, wcs: WCS?, other: FITSImage,
        op: ImageArithmetic.BinaryOp, otherHDU: Int,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage {
        let combined = try ImageArithmetic.combinedCheckingCancellation(
            image, other, op: op, checkCancellation: checkCancellation)
        return DerivedImage(image: combined, wcs: wcs,
                            label: "\(op.label) vs HDU \(otherHDU)")
    }

    public static func subtractBackground(_ image: FITSImage,
                                          wcs: WCS?) -> DerivedImage? {
        try! subtractBackgroundCheckingCancellation(image, wcs: wcs,
                                                    checkCancellation: {})
    }

    public static func subtractBackgroundCheckingCancellation(
        _ image: FITSImage, wcs: WCS?,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage? {
        let values = try image.physicalValuesCheckingCancellation(
            checkCancellation: checkCancellation)
        guard let background = try PixelStatistics.sigmaClippedOptionalCheckingCancellation(
            values, sigma: 3, iterations: 5,
            checkCancellation: checkCancellation
        ) else { return nil }
        let pixels = try image.normalizedFloat32CheckingCancellation(
            checkCancellation: checkCancellation)
        let mean = Float(background.mean)
        var output = [Float](repeating: .nan, count: pixels.count)
        for index in pixels.indices {
            if index % 256 == 0 { try checkCancellation() }
            if !pixels[index].isNaN { output[index] = pixels[index] - mean }
        }
        let subtracted = FITSImage.fromFloat32(pixels: output,
                                                width: image.width, height: image.height)
        let label = String(format: "BG sub (μ=%.3g, σ=%.3g, n=%d)",
                           background.mean, background.stddev, background.count)
        return DerivedImage(image: subtracted, wcs: wcs, label: label)
    }

    public static func reproject(_ image: FITSImage, sourceWCS: WCS,
                                 targetWCS: WCS, targetWidth: Int,
                                 targetHeight: Int, targetHDU: Int) -> DerivedImage? {
        try! reprojectCheckingCancellation(
            image, sourceWCS: sourceWCS, targetWCS: targetWCS,
            targetWidth: targetWidth, targetHeight: targetHeight,
            targetHDU: targetHDU, checkCancellation: {})
    }

    public static func reprojectCheckingCancellation(
        _ image: FITSImage, sourceWCS: WCS, targetWCS: WCS,
        targetWidth: Int, targetHeight: Int, targetHDU: Int,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage? {
        guard targetWidth > 0, targetHeight > 0,
              targetWidth <= Int.max / targetHeight else { return nil }
        let projected = try WCSReproject.reprojectCheckingCancellation(
            source: image, sourceWCS: sourceWCS,
            targetWCS: targetWCS, targetWidth: targetWidth,
            targetHeight: targetHeight, checkCancellation: checkCancellation
        )
        return DerivedImage(image: projected, wcs: targetWCS,
                            label: "Reprojected onto HDU \(targetHDU)")
    }

    /// Combine same-size displayed images on the reference document's pixel grid.
    public static func stack(_ images: [FITSImage], referenceWCS: WCS?,
                             mode: StackMode) -> DerivedImage? {
        try! stackCheckingCancellation(images, referenceWCS: referenceWCS,
                                       mode: mode, checkCancellation: {})
    }

    public static func stackCheckingCancellation(
        _ images: [FITSImage], referenceWCS: WCS?, mode: StackMode,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage? {
        guard images.count >= 2, let first = images.first,
              images.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            return nil
        }
        let width = first.width, height = first.height
        var pixels = [Float](repeating: 0, count: width * height)
        for index in pixels.indices {
            if index % 256 == 0 { try checkCancellation() }
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
        try checkCancellation()
        return DerivedImage(
            image: FITSImage.fromFloat32(pixels: pixels, width: width, height: height),
            wcs: referenceWCS,
            label: "Stack \(mode.label) of \(images.count) windows"
        )
    }

    /// Average complete factor-by-factor blocks of the displayed image.
    public static func bin(_ image: FITSImage, wcs: WCS?, factor: Int) -> DerivedImage? {
        try! binCheckingCancellation(image, wcs: wcs, factor: factor,
                                     checkCancellation: {})
    }

    public static func binCheckingCancellation(
        _ image: FITSImage, wcs: WCS?, factor: Int,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage? {
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
            try checkCancellation()
            for blockX in 0..<width {
                var sum = 0.0
                var count = 0
                for offsetY in 0..<factor {
                    for offsetX in 0..<factor {
                        if ((offsetY * factor + offsetX) & 255) == 0 {
                            try checkCancellation()
                        }
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
        try checkCancellation()
        return DerivedImage(
            image: FITSImage.fromFloat32(pixels: pixels, width: width, height: height),
            wcs: outputWCS, label: "Binned \(factor)×\(factor)"
        )
    }

    /// Copy a zero-based image rectangle, keeping its WCS origin aligned.
    public static func crop(_ image: FITSImage, wcs: WCS?, originX: Int, originY: Int,
                            width: Int, height: Int) -> DerivedImage? {
        try! cropCheckingCancellation(image, wcs: wcs, originX: originX,
                                      originY: originY, width: width, height: height,
                                      checkCancellation: {})
    }

    public static func cropCheckingCancellation(
        _ image: FITSImage, wcs: WCS?, originX: Int, originY: Int,
        width: Int, height: Int,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage? {
        guard originX >= 0, originY >= 0, width > 0, height > 0,
              width <= image.width, height <= image.height,
              originX <= image.width - width,
              originY <= image.height - height else { return nil }
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            try checkCancellation()
            for x in 0..<width {
                if x > 0 && x % 256 == 0 { try checkCancellation() }
                pixels[y * width + x] = Float(image.physicalValue(x: originX + x,
                                                                   y: originY + y))
            }
        }
        try checkCancellation()
        let maxX = originX + width - 1
        let maxY = originY + height - 1
        return DerivedImage(
            image: FITSImage.fromFloat32(pixels: pixels, width: width, height: height),
            wcs: wcs?.cropped(originX: originX, originY: originY),
            label: "Crop \(originX),\(originY) → \(maxX),\(maxY)"
        )
    }

    /// Crop to the bounding rectangle of pixels contained by a region. Region
    /// coordinates are resolved against the displayed image's WCS.
    public static func cropToRegion(_ image: FITSImage, wcs: WCS?,
                                    region: Region) -> DerivedImage? {
        try! cropToRegionCheckingCancellation(image, wcs: wcs, region: region,
                                               checkCancellation: {})
    }

    public static func cropToRegionCheckingCancellation(
        _ image: FITSImage, wcs: WCS?, region: Region,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DerivedImage? {
        guard let contains = containsPredicate(for: region, wcs: wcs) else { return nil }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<image.height {
            try checkCancellation()
            for x in 0..<image.width {
                if x > 0 && x % 256 == 0 { try checkCancellation() }
                guard contains(x, y) else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return try cropCheckingCancellation(
            image, wcs: wcs, originX: minX, originY: minY,
            width: maxX - minX + 1, height: maxY - minY + 1,
            checkCancellation: checkCancellation
        )
    }

    private static func containsPredicate(
        for region: Region, wcs: WCS?
    ) -> ((Int, Int) -> Bool)? {
        switch region.shape {
        case .circle(let center, let radius):
            guard let pixelCenter = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let pixels = pixelLength(radius, frame: region.frame, wcs: wcs) else { return nil }
            return { x, y in
                let dx = Double(x) - pixelCenter.x, dy = Double(y) - pixelCenter.y
                return dx * dx + dy * dy <= pixels * pixels
            }
        case .box(let center, let width, let height, let angle):
            guard let pixelCenter = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let pixelWidth = pixelLength(width, frame: region.frame, wcs: wcs),
                  let pixelHeight = pixelLength(height, frame: region.frame, wcs: wcs) else {
                return nil
            }
            let theta = angle * .pi / 180
            let cosTheta = cos(theta), sinTheta = sin(theta)
            return { x, y in
                let dx = Double(x) - pixelCenter.x, dy = Double(y) - pixelCenter.y
                let localX = dx * cosTheta + dy * sinTheta
                let localY = -dx * sinTheta + dy * cosTheta
                return abs(localX) <= pixelWidth / 2 && abs(localY) <= pixelHeight / 2
            }
        case .ellipse(let center, let rx, let ry, let angle):
            guard let pixelCenter = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let pixelRX = pixelLength(rx, frame: region.frame, wcs: wcs),
                  let pixelRY = pixelLength(ry, frame: region.frame, wcs: wcs),
                  pixelRX > 0, pixelRY > 0 else { return nil }
            let theta = angle * .pi / 180
            let cosTheta = cos(theta), sinTheta = sin(theta)
            return { x, y in
                let dx = Double(x) - pixelCenter.x, dy = Double(y) - pixelCenter.y
                let localX = dx * cosTheta + dy * sinTheta
                let localY = -dx * sinTheta + dy * cosTheta
                let nx = localX / pixelRX, ny = localY / pixelRY
                return nx * nx + ny * ny <= 1
            }
        case .annulus(let center, let inner, let outer):
            guard let pixelCenter = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let pixelInner = pixelLength(inner, frame: region.frame, wcs: wcs),
                  let pixelOuter = pixelLength(outer, frame: region.frame, wcs: wcs) else {
                return nil
            }
            return { x, y in
                let dx = Double(x) - pixelCenter.x, dy = Double(y) - pixelCenter.y
                let distance2 = dx * dx + dy * dy
                return distance2 >= pixelInner * pixelInner &&
                    distance2 <= pixelOuter * pixelOuter
            }
        case .polygon(let points):
            guard region.frame == .image, points.count >= 3 else { return nil }
            return { x, y in
                var inside = false
                var previous = points.count - 1
                for index in points.indices {
                    let xi = points[index].x - 1, yi = points[index].y - 1
                    let xj = points[previous].x - 1, yj = points[previous].y - 1
                    let px = Double(x), py = Double(y)
                    if ((yi > py) != (yj > py)) &&
                       (px < (xj - xi) * (py - yi) / (yj - yi + 1e-30) + xi) {
                        inside.toggle()
                    }
                    previous = index
                }
                return inside
            }
        case .point:
            return nil
        }
    }
}
