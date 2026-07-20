import XCTest
@testable import FITSCore

final class GaussianFitTests: XCTestCase {
    private func gaussian(width w: Int, height h: Int, x0: Double, y0: Double,
                          sigma: Double, amp: Double, bg: Double = 0) -> FITSImage {
        var pix = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x) - x0, dy = Double(y) - y0
                pix[y * w + x] = Float(bg + amp * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
            }
        }
        return FITSImage.fromFloat32(pixels: pix, width: w, height: h)
    }

    func testRecoversCenterAmplitudeAndSigma() {
        let img = gaussian(width: 21, height: 21, x0: 10.3, y0: 9.8, sigma: 2.0, amp: 100, bg: 5)
        let fit = GaussianFit.fit(image: img, near: (10, 10), boxRadius: 7)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.x, 10.3, accuracy: 0.05)
        XCTAssertEqual(fit!.y, 9.8, accuracy: 0.05)
        XCTAssertEqual(fit!.sigmaX, 2.0, accuracy: 0.1)
        XCTAssertEqual(fit!.sigmaY, 2.0, accuracy: 0.1)
        XCTAssertEqual(fit!.amplitude, 100, accuracy: 1)
        XCTAssertEqual(fit!.background, 5, accuracy: 0.5)
    }

    func testFWHMMatchesGaussianRelationship() {
        // FWHM = 2 sqrt(2 ln 2) * σ
        let img = gaussian(width: 21, height: 21, x0: 10, y0: 10, sigma: 3.0, amp: 50)
        let fit = GaussianFit.fit(image: img, near: (10, 10), boxRadius: 8)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.fwhm, 2.0 * sqrt(2 * log(2)) * 3.0, accuracy: 0.2)
    }

    func testReturnsNilWhenNoSignal() {
        let img = FITSImage.fromFloat32(pixels: [Float](repeating: 5, count: 121), width: 11, height: 11)
        let fit = GaussianFit.fit(image: img, near: (5, 5), boxRadius: 4)
        // Flat background — fit may converge but amplitude should be ~0.
        XCTAssertTrue(fit == nil || abs(fit!.amplitude) < 1)
    }
}
