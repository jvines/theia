import XCTest
@testable import FITSCore

final class Gaussian1DTests: XCTestCase {
    func testFitsSyntheticGaussian() {
        // 100 channels, Gaussian peak at x=50, sigma=3, amp=20, baseline=5.
        let xs = (0..<100).map(Double.init)
        let ys = xs.map { x -> Double in
            5 + 20 * exp(-(x - 50) * (x - 50) / (2 * 9))
        }
        let fit = Gaussian1D.fit(xs: xs, ys: ys, near: 50, halfWidth: 15)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.center, 50, accuracy: 0.5)
        XCTAssertEqual(fit!.sigma, 3, accuracy: 0.3)
        XCTAssertEqual(fit!.amplitude, 20, accuracy: 1)
        XCTAssertEqual(fit!.baseline, 5, accuracy: 0.5)
    }

    func testReturnsNilOnEmptyRange() {
        XCTAssertNil(Gaussian1D.fit(xs: [], ys: [], near: 0, halfWidth: 5))
    }
}
