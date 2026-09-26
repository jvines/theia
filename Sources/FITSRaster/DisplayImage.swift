import FITSCore

/// A decoded image plane for display. The caller owns its revision and may build
/// this value off the main actor before applying it to a document session.
public struct DisplayImage: Sendable {
    public let width: Int
    public let height: Int
    public let revision: Int
    /// Physical pixel values in FITS row order, starting at the bottom-left pixel.
    public let pixels: [Float]
    /// A deterministic sample for rebuilding the display CDF as levels change.
    public let sortedFiniteSample: [Float]
    public let initialLevels: RasterLevels

    public init(image: FITSImage, revision: Int) {
        self.width = image.width
        self.height = image.height
        self.revision = revision
        let pixels = image.normalizedFloat32()
        self.pixels = pixels
        self.sortedFiniteSample = Self.makeSortedFiniteSample(pixels)
        if let range = image.defaultRange() {
            self.initialLevels = RasterLevels(vmin: Float(range.z1), vmax: Float(range.z2))
        } else if let first = sortedFiniteSample.first, let last = sortedFiniteSample.last {
            self.initialLevels = RasterLevels(vmin: first, vmax: last)
        } else {
            self.initialLevels = RasterLevels(vmin: 0, vmax: 1)
        }
    }

    private static func makeSortedFiniteSample(_ pixels: [Float]) -> [Float] {
        let limit = 1 << 20
        let finiteCount = pixels.reduce(into: 0) { count, value in
            if value.isFinite { count += 1 }
        }
        if finiteCount <= limit {
            return pixels.filter(\.isFinite).sorted()
        }

        var sample = [Float]()
        sample.reserveCapacity(limit)
        var finiteIndex = 0
        var wantedIndex = 0
        for value in pixels where value.isFinite {
            if finiteIndex == wantedIndex {
                sample.append(value)
                if sample.count == limit { break }
                wantedIndex = sample.count * (finiteCount - 1) / (limit - 1)
            }
            finiteIndex += 1
        }
        sample.sort()
        return sample
    }
}
