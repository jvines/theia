import XCTest
@testable import FITSCore

final class ImageStretchTests: XCTestCase {
    func testLinearMapsRangeToZeroOne() {
        XCTAssertEqual(ImageStretch.linear.apply(0, vmin: 0, vmax: 10), 0)
        XCTAssertEqual(ImageStretch.linear.apply(5, vmin: 0, vmax: 10), 0.5)
        XCTAssertEqual(ImageStretch.linear.apply(10, vmin: 0, vmax: 10), 1)
    }

    func testLinearClampsOutsideRange() {
        XCTAssertEqual(ImageStretch.linear.apply(-5, vmin: 0, vmax: 10), 0)
        XCTAssertEqual(ImageStretch.linear.apply(20, vmin: 0, vmax: 10), 1)
    }

    func testLogStretchIsConcaveAndAnchored() {
        XCTAssertEqual(ImageStretch.log.apply(0, vmin: 0, vmax: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(ImageStretch.log.apply(1, vmin: 0, vmax: 1), 1, accuracy: 1e-12)
        let mid = ImageStretch.log.apply(0.5, vmin: 0, vmax: 1)
        XCTAssertEqual(mid, log10(5.5), accuracy: 1e-12)
        XCTAssertGreaterThan(mid, 0.5)  // concave: brightens low values
    }

    func testSqrtStretchMatchesSquareRoot() {
        XCTAssertEqual(ImageStretch.sqrt.apply(0, vmin: 0, vmax: 1), 0)
        XCTAssertEqual(ImageStretch.sqrt.apply(0.25, vmin: 0, vmax: 1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ImageStretch.sqrt.apply(1, vmin: 0, vmax: 1), 1)
    }

    func testAsinhStretchIsConcaveAndAnchored() {
        XCTAssertEqual(ImageStretch.asinh.apply(0, vmin: 0, vmax: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(ImageStretch.asinh.apply(1, vmin: 0, vmax: 1), 1, accuracy: 1e-12)
        let mid = ImageStretch.asinh.apply(0.5, vmin: 0, vmax: 1)
        XCTAssertGreaterThan(mid, 0.5)
    }

    func testHistogramEqUsesCDFLookup() {
        // CDF [0.1, 0.4, 0.7, 1.0] — 4 entries. x=0 → cdf[0]=0.1; x=1 → cdf[3]=1.0; x=0.5 → cdf[1]=0.4.
        let cdf = [0.1, 0.4, 0.7, 1.0]
        XCTAssertEqual(ImageStretch.histogramEq.apply(0, vmin: 0, vmax: 1, cdf: cdf), 0.1)
        XCTAssertEqual(ImageStretch.histogramEq.apply(1, vmin: 0, vmax: 1, cdf: cdf), 1.0)
        XCTAssertEqual(ImageStretch.histogramEq.apply(0.5, vmin: 0, vmax: 1, cdf: cdf), 0.4)
    }

    func testHistogramEqWithoutCDFFallsBackToLinear() {
        XCTAssertEqual(ImageStretch.histogramEq.apply(0.5, vmin: 0, vmax: 1, cdf: nil), 0.5)
    }

    func testNaNPropagatesAcrossStretches() {
        for s in ImageStretch.allCases {
            XCTAssertTrue(s.apply(.nan, vmin: 0, vmax: 1).isNaN, "\(s) should propagate NaN")
        }
    }

    // MARK: - Power stretch

    func testPowerWithExponentOneEqualsLinear() {
        XCTAssertEqual(ImageStretch.power.apply(0.0, vmin: 0, vmax: 1, parameter: 1.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(ImageStretch.power.apply(0.5, vmin: 0, vmax: 1, parameter: 1.0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ImageStretch.power.apply(1.0, vmin: 0, vmax: 1, parameter: 1.0), 1.0, accuracy: 1e-12)
    }

    func testPowerWithExponentHalfMatchesSqrt() {
        // x^0.5 == sqrt(x)
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            let p = ImageStretch.power.apply(x, vmin: 0, vmax: 1, parameter: 0.5)
            XCTAssertEqual(p, x.squareRoot(), accuracy: 1e-12)
        }
    }

    func testPowerWithExponentTwoCompressesDarkValues() {
        let mid = ImageStretch.power.apply(0.5, vmin: 0, vmax: 1, parameter: 2.0)
        XCTAssertEqual(mid, 0.25, accuracy: 1e-12)
        XCTAssertLessThan(mid, 0.5)  // exponent > 1 darkens midtones
    }

    func testPowerClampsAtRangeEnds() {
        XCTAssertEqual(ImageStretch.power.apply(-5, vmin: 0, vmax: 1, parameter: 2.0), 0)
        XCTAssertEqual(ImageStretch.power.apply(99, vmin: 0, vmax: 1, parameter: 2.0), 1)
    }

    func testPowerWithoutParameterDefaultsToSquare() {
        // Default parameter is 2.0 — squashes midtones.
        XCTAssertEqual(ImageStretch.power.apply(0.5, vmin: 0, vmax: 1), 0.25, accuracy: 1e-12)
    }
}
