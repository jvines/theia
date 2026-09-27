import XCTest
@testable import FITSCore

final class PixelStatisticsTests: XCTestCase {
    func testNaNAwareMinMaxSkipsNaN() {
        let values: [Double] = [1.0, 5.0, .nan, 3.0, .nan, 2.0]
        let r = PixelStatistics.minMax(values)
        XCTAssertEqual(r?.min, 1.0)
        XCTAssertEqual(r?.max, 5.0)
    }

    func testHistogramCountsBinsCorrectly() {
        let values: [Double] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        let h = PixelStatistics.histogram(values, bins: 5, range: 0...10)
        XCTAssertEqual(h.counts, [2, 2, 2, 2, 2])
        XCTAssertEqual(h.edges, [0, 2, 4, 6, 8, 10])
    }

    func testHistogramIncludesMaximumInLastBin() {
        let values: [Double] = [0, 10]
        let h = PixelStatistics.histogram(values, bins: 2, range: 0...10)
        XCTAssertEqual(h.counts, [1, 1])
    }

    func testHistogramClampsRoundedMaximumToLastBin() {
        let high = Double.leastNonzeroMagnitude * 257
        let histogram = PixelStatistics.histogram([0, high], bins: 256, range: 0...high)
        XCTAssertEqual(histogram.counts[0], 1)
        XCTAssertEqual(histogram.counts[255], 1)
        XCTAssertEqual(histogram.counts.reduce(0, +), 2)
    }

    func testHistogramSkipsNaN() {
        let values: [Double] = [1, .nan, 2]
        let h = PixelStatistics.histogram(values, bins: 3, range: 0...3)
        XCTAssertEqual(h.counts.reduce(0, +), 2)
    }

    func testCDFIsMonotonicallyIncreasingFromZeroToOne() {
        let h = Histogram(counts: [1, 2, 3, 4], edges: [0, 1, 2, 3, 4])
        let cdf = h.cdf()
        XCTAssertEqual(cdf.count, 4)
        XCTAssertEqual(cdf[0], 0.1, accuracy: 1e-12)  // 1/10
        XCTAssertEqual(cdf[1], 0.3, accuracy: 1e-12)  // 3/10
        XCTAssertEqual(cdf[2], 0.6, accuracy: 1e-12)  // 6/10
        XCTAssertEqual(cdf[3], 1.0, accuracy: 1e-12)
    }

    func testCDFAllZerosReturnsAllZeros() {
        let h = Histogram(counts: [0, 0, 0], edges: [0, 1, 2, 3])
        XCTAssertEqual(h.cdf(), [0, 0, 0])
    }

    func testZScaleRejectsBrightOutliers() {
        // 590 background pixels in [99, 102], 10 outliers at 100000
        var values = [Double]()
        for i in 0..<590 { values.append(99.0 + Double(i % 300) / 100.0) }
        values.append(contentsOf: Array(repeating: 100000.0, count: 10))
        let r = PixelStatistics.zscale(values, contrast: 0.25)
        XCTAssertNotNil(r)
        // Outliers should not pull z2 close to 100000.
        XCTAssertLessThan(r!.z2, 1000)
        XCTAssertGreaterThan(r!.z1, 50)
    }

    func testZScaleSkipsNaN() {
        let values: [Double] = [.nan, 1, 2, 3, 4, 5, .nan, 6, 7, 8, 9, 10]
        let r = PixelStatistics.zscale(values, contrast: 1.0)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.z1, 1, accuracy: 1)
        XCTAssertEqual(r!.z2, 10, accuracy: 1)
    }

    func testZScaleSkipsInfiniteSamples() {
        let values: [Double] = [-.infinity, 1, 2, 3, 4, 5, .infinity]
        let result = PixelStatistics.zscale(values, contrast: 1)
        XCTAssertEqual(result?.z1, 1)
        XCTAssertEqual(result?.z2, 5)
    }

    func testZScaleOnUniformRampApproximatesFullRangeAtContrastOne() {
        let values = (1...600).map(Double.init)
        let r = PixelStatistics.zscale(values, contrast: 1.0)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.z1, 1.0, accuracy: 2.0)
        XCTAssertEqual(r!.z2, 600.0, accuracy: 2.0)
    }

    func testZScaleSamplesSourceWithoutReadingEveryPixel() {
        let values = (0..<12_000).map { Double($0 % 301) }
        var reads = 0
        let sampled = PixelStatistics.zscaleSampled(pixelCount: values.count) { index in
            reads += 1
            return values[index]
        }
        let arrayResult = PixelStatistics.zscale(values)
        XCTAssertEqual(sampled?.z1, arrayResult?.z1)
        XCTAssertEqual(sampled?.z2, arrayResult?.z2)
        XCTAssertLessThanOrEqual(reads, 600)
    }

    func testEqualizeMapsValueToCDFEntry() {
        // 10 bins of 1 count each over [0,10]. CDF = [.1, .2, ..., 1.0].
        let h = Histogram(counts: Array(repeating: 1, count: 10), edges: (0...10).map(Double.init))
        XCTAssertEqual(h.equalize(0.5), 0.1, accuracy: 1e-12)
        XCTAssertEqual(h.equalize(5.0), 0.6, accuracy: 1e-12)
        XCTAssertEqual(h.equalize(9.5), 1.0, accuracy: 1e-12)
    }

    func testEqualizeClampsOutsideRange() {
        let h = Histogram(counts: [1, 1, 1], edges: [0, 1, 2, 3])
        XCTAssertEqual(h.equalize(-5), 0)
        XCTAssertEqual(h.equalize(100), 1)
    }

    func testEqualizePropagatesNaN() {
        let h = Histogram(counts: [1, 1], edges: [0, 1, 2])
        XCTAssertTrue(h.equalize(.nan).isNaN)
    }

    func testMinMaxOfAllNaNReturnsNil() {
        let values: [Double] = [.nan, .nan, .nan]
        XCTAssertNil(PixelStatistics.minMax(values))
    }

    // MARK: - percentiles

    func testPercentilesFullRangeReturnsMinMax() {
        let values = (1...100).map(Double.init)
        let r = PixelStatistics.percentiles(values, lower: 0, upper: 100)
        XCTAssertEqual(r!.vmin, 1, accuracy: 1e-9)
        XCTAssertEqual(r!.vmax, 100, accuracy: 1e-9)
    }

    func testPercentilesNinetyNineRejectsTopOnePercent() {
        // values 1..100 — 99th percentile is 99, 1st percentile is 2 (linear interp)
        let values = (1...100).map(Double.init)
        let r = PixelStatistics.percentiles(values, lower: 1, upper: 99)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.vmin, 2.0, accuracy: 0.5)
        XCTAssertEqual(r!.vmax, 99.0, accuracy: 0.5)
    }

    func testPercentilesSkipsNaN() {
        var values = (1...100).map(Double.init)
        values.append(contentsOf: [Double](repeating: .nan, count: 50))
        let r = PixelStatistics.percentiles(values, lower: 0, upper: 100)
        XCTAssertEqual(r!.vmin, 1, accuracy: 1e-9)
        XCTAssertEqual(r!.vmax, 100, accuracy: 1e-9)
    }

    func testPercentilesAllNaNReturnsNil() {
        let values: [Double] = [.nan, .nan]
        XCTAssertNil(PixelStatistics.percentiles(values, lower: 1, upper: 99))
    }

    func testPercentilesEmptyReturnsNil() {
        XCTAssertNil(PixelStatistics.percentiles([], lower: 1, upper: 99))
    }

    func testPercentilesSingleValueDegenerates() {
        let r = PixelStatistics.percentiles([42.0], lower: 1, upper: 99)
        XCTAssertEqual(r?.vmin ?? .nan, 42)
        XCTAssertEqual(r?.vmax ?? .nan, 42)
    }

    func testPercentilesClampsOutOfRangeBounds() {
        let values = (1...10).map(Double.init)
        // lower < 0 and upper > 100 should clamp to [0, 100]
        let r = PixelStatistics.percentiles(values, lower: -5, upper: 150)
        XCTAssertEqual(r!.vmin, 1, accuracy: 1e-9)
        XCTAssertEqual(r!.vmax, 10, accuracy: 1e-9)
    }

    // MARK: - sigma-clipped background

    func testSigmaClippedMeanSurvivesOutliers() {
        // 1000 normal-ish values + a few 100× outliers. Clipped mean should be near 0.
        var rng = SystemRandomNumberGenerator()
        var v: [Double] = (0..<1000).map { _ in Double.random(in: -1...1, using: &rng) }
        v.append(contentsOf: [10000, -10000, 8000])
        let r = PixelStatistics.sigmaClipped(v, sigma: 3, iterations: 5)
        XCTAssertEqual(r.mean, 0, accuracy: 0.5)
        XCTAssertEqual(r.stddev, 1.0 / sqrt(3), accuracy: 0.5)  // uniform [-1,1] σ = 1/√3
    }

    func testSigmaClippedAllNaNReturnsNil() {
        XCTAssertNil(PixelStatistics.sigmaClippedOptional([.nan, .nan], sigma: 3, iterations: 3))
    }

    func testCancellableSigmaClipMatchesExistingResult() throws {
        let values = [Double](repeating: 10, count: 10_000) + [12, .nan, 1_000]
        let expected = PixelStatistics.sigmaClippedOptional(values, sigma: 3, iterations: 5)
        let actual = try PixelStatistics.sigmaClippedOptionalCheckingCancellation(
            values, sigma: 3, iterations: 5
        )
        XCTAssertEqual(actual, expected)
    }

    func testSigmaClipChecksCancellationDuringFullImageScan() {
        enum Stop: Error { case requested }
        let values = [Double](repeating: 10, count: 20_000)
        var checks = 0
        XCTAssertThrowsError(try PixelStatistics.sigmaClippedOptionalCheckingCancellation(
            values, sigma: 3, iterations: 5,
            checkCancellation: {
                checks += 1
                if checks == 3 { throw Stop.requested }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(checks, 3)
    }

    func testPercentilesSwappedBoundsSwapsThem() {
        let values = (1...10).map(Double.init)
        let r = PixelStatistics.percentiles(values, lower: 99, upper: 1)
        XCTAssertNotNil(r)
        XCTAssertLessThanOrEqual(r!.vmin as Double, r!.vmax as Double)
    }
}
