import XCTest
@testable import FITSCore

final class PhotometryTests: XCTestCase {
    private func ramp(width: Int, height: Int, fill: Float = 1) -> FITSImage {
        let pix = [Float](repeating: fill, count: width * height)
        return FITSImage.fromFloat32(pixels: pix, width: width, height: height)
    }

    private func centerSpike(width w: Int, height h: Int, peak: Float, background: Float = 0) -> FITSImage {
        var pix = [Float](repeating: background, count: w * h)
        pix[(h / 2) * w + (w / 2)] = peak
        return FITSImage.fromFloat32(pixels: pix, width: w, height: h)
    }

    // MARK: - Circle aperture

    func testCirclePhotometryUniformImage() {
        let img = ramp(width: 20, height: 20)
        let region = Region(
            shape: .circle(center: .init(x: 11, y: 11), radius: .init(value: 5, unit: .pixel)),
            frame: .image
        )
        let p = Photometry.measure(region: region, image: img, wcs: nil)!
        XCTAssertGreaterThan(p.pixelCount, 0)
        // For uniform image=1, sum ≈ pixelCount.
        XCTAssertEqual(p.sum, Double(p.pixelCount), accuracy: 1e-6)
        XCTAssertEqual(p.mean, 1.0, accuracy: 1e-6)
        XCTAssertNil(p.sky)
        XCTAssertNil(p.skySubtractedFlux)
    }

    func testCirclePhotometryCentralSpike() {
        let img = centerSpike(width: 11, height: 11, peak: 100, background: 1)
        let region = Region(
            shape: .circle(center: .init(x: 6, y: 6), radius: .init(value: 1.5, unit: .pixel)),
            frame: .image
        )
        let p = Photometry.measure(region: region, image: img, wcs: nil)!
        // r=1.5 → corner pixels (distance √2≈1.41) included → full 3×3 block.
        // Sum = 100 + 8*1 = 108; mean = 108/9 = 12.
        XCTAssertEqual(p.sum, 108, accuracy: 1e-6)
        XCTAssertEqual(p.pixelCount, 9)
        XCTAssertEqual(p.mean, 108.0 / 9.0, accuracy: 1e-6)
    }

    func testCircleCentroidIsCenterForSymmetricSpike() {
        let img = centerSpike(width: 11, height: 11, peak: 100, background: 0)
        let region = Region(
            shape: .circle(center: .init(x: 6, y: 6), radius: .init(value: 2, unit: .pixel)),
            frame: .image
        )
        let p = Photometry.measure(region: region, image: img, wcs: nil)!
        // Centroid in 0-based image coords.
        XCTAssertEqual(p.centroid.x, 5, accuracy: 1e-6)  // FITS 1-based 6 → 0-based 5
        XCTAssertEqual(p.centroid.y, 5, accuracy: 1e-6)
    }

    // MARK: - Annulus (background subtraction)

    func testAnnulusReportsSkyAndSubtractedFlux() {
        // 21×21 image: peak=100 in inner disc (radius ≤ 2), background=1 elsewhere.
        let w = 21, h = 21
        var pix = [Float](repeating: 1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x - 10), dy = Double(y - 10)
                if dx * dx + dy * dy <= 4 { pix[y * w + x] = 100 }
            }
        }
        let img = FITSImage.fromFloat32(pixels: pix, width: w, height: h)
        let region = Region(
            shape: .annulus(center: .init(x: 11, y: 11),
                            innerRadius: .init(value: 5, unit: .pixel),
                            outerRadius: .init(value: 8, unit: .pixel)),
            frame: .image
        )
        let p = Photometry.measure(region: region, image: img, wcs: nil)!
        // Sky annulus has background=1 → mean sky should be 1.
        XCTAssertEqual(p.sky ?? 0, 1.0, accuracy: 1e-6)
        // sum is the annulus sum; subtracted is sum - sky*nPixels = 0 since uniform.
        XCTAssertEqual(p.skySubtractedFlux ?? 1, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(p.pixelCount, 0)
    }

    func testNaNPixelsSkipped() {
        var pix = [Float](repeating: 1, count: 9)
        pix[4] = .nan  // centre NaN
        let img = FITSImage.fromFloat32(pixels: pix, width: 3, height: 3)
        let region = Region(
            shape: .circle(center: .init(x: 2, y: 2), radius: .init(value: 5, unit: .pixel)),
            frame: .image
        )
        let p = Photometry.measure(region: region, image: img, wcs: nil)!
        XCTAssertEqual(p.pixelCount, 8)  // 9 - 1 NaN
        XCTAssertEqual(p.sum, 8, accuracy: 1e-6)
    }

    func testRejectsNonImageFrameWithoutWCS() {
        let region = Region(
            shape: .circle(center: .init(x: 180, y: 0), radius: .init(value: 5, unit: .arcsecond)),
            frame: .fk5
        )
        let img = ramp(width: 10, height: 10)
        XCTAssertNil(Photometry.measure(region: region, image: img, wcs: nil))
    }
}
