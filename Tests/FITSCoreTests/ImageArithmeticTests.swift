import XCTest
@testable import FITSCore

final class ImageArithmeticTests: XCTestCase {
    func testDifferenceOfIdenticalImagesIsZero() throws {
        let a = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let b = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let diff = try ImageArithmetic.difference(a, minus: b)
        for y in 0..<2 {
            for x in 0..<2 {
                XCTAssertEqual(diff.physicalValue(x: x, y: y), 0, accuracy: 1e-6)
            }
        }
    }

    func testDifferenceComputesPerPixel() throws {
        let a = FITSImage.fromFloat32(pixels: [10, 20, 30, 40], width: 2, height: 2)
        let b = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let diff = try ImageArithmetic.difference(a, minus: b)
        XCTAssertEqual(diff.physicalValue(x: 0, y: 0), 9, accuracy: 1e-6)
        XCTAssertEqual(diff.physicalValue(x: 1, y: 0), 18, accuracy: 1e-6)
        XCTAssertEqual(diff.physicalValue(x: 0, y: 1), 27, accuracy: 1e-6)
        XCTAssertEqual(diff.physicalValue(x: 1, y: 1), 36, accuracy: 1e-6)
    }

    func testDifferenceWithNaNPropagatesNaN() throws {
        let a = FITSImage.fromFloat32(pixels: [.nan, 5], width: 2, height: 1)
        let b = FITSImage.fromFloat32(pixels: [1, .nan], width: 2, height: 1)
        let diff = try ImageArithmetic.difference(a, minus: b)
        XCTAssertTrue(diff.physicalValue(x: 0, y: 0).isNaN)
        XCTAssertTrue(diff.physicalValue(x: 1, y: 0).isNaN)
    }

    func testDifferenceWithDimensionMismatchThrows() {
        let a = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let b = FITSImage.fromFloat32(pixels: [1, 2, 3], width: 3, height: 1)
        XCTAssertThrowsError(try ImageArithmetic.difference(a, minus: b)) { err in
            guard let e = err as? ImageArithmetic.ArithmeticError else {
                XCTFail("wrong error type"); return
            }
            XCTAssertEqual(e, .dimensionMismatch)
        }
    }
}
