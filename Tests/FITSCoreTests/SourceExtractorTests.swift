import XCTest
@testable import FITSCore

final class SourceExtractorTests: XCTestCase {
    private func gaussianImage(width w: Int, height h: Int, peaks: [(x: Double, y: Double, amp: Double, sigma: Double)], background: Float = 0.5) -> FITSImage {
        var pix = [Float](repeating: background, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v = Double(background)
                for p in peaks {
                    let dx = Double(x) - p.x, dy = Double(y) - p.y
                    v += p.amp * exp(-(dx * dx + dy * dy) / (2 * p.sigma * p.sigma))
                }
                pix[y * w + x] = Float(v)
            }
        }
        return FITSImage.fromFloat32(pixels: pix, width: w, height: h)
    }

    func testFindsSinglePeakAboveThreshold() {
        let img = gaussianImage(width: 21, height: 21,
                                peaks: [(x: 10, y: 10, amp: 100, sigma: 1.5)],
                                background: 0.5)
        let sources = SourceExtractor.detect(image: img, threshold: 5, minSeparation: 2)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].x, 10, accuracy: 0.5)
        XCTAssertEqual(sources[0].y, 10, accuracy: 0.5)
        XCTAssertGreaterThan(sources[0].peak, 50)
    }

    func testFindsTwoWellSeparatedPeaks() {
        let img = gaussianImage(width: 41, height: 41,
                                peaks: [(x: 10, y: 20, amp: 50, sigma: 2),
                                        (x: 30, y: 20, amp: 40, sigma: 2)],
                                background: 0.5)
        let sources = SourceExtractor.detect(image: img, threshold: 5, minSeparation: 5)
        XCTAssertEqual(sources.count, 2)
        let xs = sources.map { $0.x }.sorted()
        XCTAssertEqual(xs[0], 10, accuracy: 1)
        XCTAssertEqual(xs[1], 30, accuracy: 1)
    }

    func testIgnoresPeaksBelowThreshold() {
        let img = gaussianImage(width: 21, height: 21,
                                peaks: [(x: 10, y: 10, amp: 1, sigma: 1.5)],
                                background: 0.5)
        let sources = SourceExtractor.detect(image: img, threshold: 5, minSeparation: 2)
        XCTAssertEqual(sources.count, 0)
    }

    func testMinSeparationDeduplicatesAdjacent() {
        // Two extremely close peaks → should yield one detection with minSeparation > spacing.
        let img = gaussianImage(width: 21, height: 21,
                                peaks: [(x: 10, y: 10, amp: 100, sigma: 1.5),
                                        (x: 11, y: 10, amp: 90, sigma: 1.5)],
                                background: 0.5)
        let sources = SourceExtractor.detect(image: img, threshold: 5, minSeparation: 3)
        XCTAssertEqual(sources.count, 1)
    }

    func testFindsPeaksOnGradientBackground() {
        // Background gradient from 0 to 100 across the image, plus three small peaks
        // each ~10× their local background. A global mean+5σ threshold would either
        // mask all real peaks (if threshold > local) or fire on the high-side ramp.
        let w = 51, h = 51
        var pix = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                pix[y * w + x] = Float(x)  // background rises with x
            }
        }
        let peaks = [(x: 10, y: 25), (x: 25, y: 25), (x: 40, y: 25)]
        for p in peaks {
            pix[p.y * w + p.x] += Float(50)
        }
        let img = FITSImage.fromFloat32(pixels: pix, width: w, height: h)
        let sources = SourceExtractor.detect(image: img, threshold: nil,
                                             minSeparation: 3, backgroundBoxSize: 11, nSigma: 4)
        XCTAssertEqual(sources.count, peaks.count)
        let xs = sources.map { Int($0.x.rounded()) }.sorted()
        XCTAssertEqual(xs, [10, 25, 40])
    }

    func testCentroidRefinesSubpixel() {
        // Peak placed at non-integer location → centroid should report the true location.
        let img = gaussianImage(width: 21, height: 21,
                                peaks: [(x: 10.3, y: 10.7, amp: 100, sigma: 2)],
                                background: 0.5)
        let sources = SourceExtractor.detect(image: img, threshold: 5, minSeparation: 2)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].x, 10.3, accuracy: 0.2)
        XCTAssertEqual(sources[0].y, 10.7, accuracy: 0.2)
    }
}
