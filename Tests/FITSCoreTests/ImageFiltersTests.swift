import XCTest
@testable import FITSCore

final class ImageFiltersTests: XCTestCase {
    // MARK: - Boxcar

    func testBoxcar3x3OnUniformImageIsUnchanged() {
        let img = makeImage(width: 4, height: 4, fill: 1)
        let out = ImageFilters.boxcar(img, size: 3)
        for i in 0..<16 {
            XCTAssertEqual(out.pixel(i), 1, accuracy: 1e-6)
        }
    }

    func testBoxcar3x3SmoothsSinglePeak() {
        // 5×5 image with central pixel = 9, others = 0. After 3×3 boxcar mean, the
        // central pixel value = 9/9 = 1, neighbours = 9/9 = 1, two-away = 0.
        var pix = [Float](repeating: 0, count: 25)
        pix[2 * 5 + 2] = 9
        let img = FITSImage.fromFloat32(pixels: pix, width: 5, height: 5)
        let out = ImageFilters.boxcar(img, size: 3)
        XCTAssertEqual(out.pixel(at: 2, 2), 1, accuracy: 1e-6)
        XCTAssertEqual(out.pixel(at: 1, 2), 1, accuracy: 1e-6)
        XCTAssertEqual(out.pixel(at: 3, 2), 1, accuracy: 1e-6)
        XCTAssertEqual(out.pixel(at: 0, 2), 0, accuracy: 1e-6)
    }

    // MARK: - Gaussian

    func testGaussianMonotonicallyDecreasesFromPeak() {
        var pix = [Float](repeating: 0, count: 49)
        pix[3 * 7 + 3] = 100
        let img = FITSImage.fromFloat32(pixels: pix, width: 7, height: 7)
        let out = ImageFilters.gaussian(img, sigma: 1.0)
        let center = out.pixel(at: 3, 3)
        let oneAway = out.pixel(at: 4, 3)
        let twoAway = out.pixel(at: 5, 3)
        XCTAssertGreaterThan(center, oneAway)
        XCTAssertGreaterThan(oneAway, twoAway)
    }

    // MARK: - Median

    func testMedianRemovesSinglePixelOutlier() {
        // 5×5 image of zeros with a single 1000-valued spike at the centre.
        // 3×3 median should suppress it to 0.
        var pix = [Float](repeating: 0, count: 25)
        pix[2 * 5 + 2] = 1000
        let img = FITSImage.fromFloat32(pixels: pix, width: 5, height: 5)
        let out = ImageFilters.median(img, size: 3)
        XCTAssertEqual(out.pixel(at: 2, 2), 0, accuracy: 1e-6)
    }

    // MARK: - Arithmetic

    func testSumDimensionMismatchThrows() {
        let a = makeImage(width: 2, height: 2, fill: 1)
        let b = makeImage(width: 3, height: 3, fill: 1)
        XCTAssertThrowsError(try ImageArithmetic.combined(a, b, op: .sum))
    }

    func testSumIsElementwise() throws {
        let a = makeImage(width: 2, height: 2, fill: 3)
        let b = makeImage(width: 2, height: 2, fill: 4)
        let out = try ImageArithmetic.combined(a, b, op: .sum)
        for i in 0..<4 { XCTAssertEqual(out.pixel(i), 7, accuracy: 1e-6) }
    }

    func testRatioIsElementwise() throws {
        let a = makeImage(width: 1, height: 1, fill: 10)
        let b = makeImage(width: 1, height: 1, fill: 4)
        let out = try ImageArithmetic.combined(a, b, op: .ratio)
        XCTAssertEqual(out.pixel(0), 2.5, accuracy: 1e-6)
    }

    func testLogClampsNegativeAndZeroToNaN() {
        let img = FITSImage.fromFloat32(pixels: [-1, 0, 1, 10], width: 2, height: 2)
        let out = ImageArithmetic.unary(img, op: .log10)
        XCTAssertTrue(out.pixel(0).isNaN)
        XCTAssertTrue(out.pixel(1).isNaN)
        XCTAssertEqual(out.pixel(2), 0, accuracy: 1e-6)
        XCTAssertEqual(out.pixel(3), 1, accuracy: 1e-6)
    }

    func testSqrtClampsNegativeToNaN() {
        let img = FITSImage.fromFloat32(pixels: [-4, 0, 4, 9], width: 2, height: 2)
        let out = ImageArithmetic.unary(img, op: .sqrt)
        XCTAssertTrue(out.pixel(0).isNaN)
        XCTAssertEqual(out.pixel(1), 0)
        XCTAssertEqual(out.pixel(2), 2, accuracy: 1e-6)
        XCTAssertEqual(out.pixel(3), 3, accuracy: 1e-6)
    }

    // MARK: - helpers

    private func makeImage(width: Int, height: Int, fill: Float) -> FITSImage {
        let pix = [Float](repeating: fill, count: width * height)
        return FITSImage.fromFloat32(pixels: pix, width: width, height: height)
    }
}

private extension FITSImage {
    func pixel(_ i: Int) -> Double {
        physicalValue(x: i % width, y: i / width)
    }
    func pixel(at x: Int, _ y: Int) -> Double {
        physicalValue(x: x, y: y)
    }
}
