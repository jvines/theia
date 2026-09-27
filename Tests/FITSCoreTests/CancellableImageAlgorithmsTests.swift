import XCTest
@testable import FITSCore

final class CancellableImageAlgorithmsTests: XCTestCase {
    private enum Stop: Error { case requested }

    func testFiltersMatchExistingOutputsIncludingNaN() throws {
        let image = FITSImage.fromFloat32(
            pixels: [1, 2, .nan, 4, 5, 6, 7, 8, 9], width: 3, height: 3
        )
        try assertSamePixels(ImageFilters.boxcar(image, size: 3),
                             ImageFilters.boxcarCheckingCancellation(image, size: 3))
        try assertSamePixels(ImageFilters.median(image, size: 3),
                             ImageFilters.medianCheckingCancellation(image, size: 3))
        try assertSamePixels(ImageFilters.gaussian(image, sigma: 1),
                             ImageFilters.gaussianCheckingCancellation(image, sigma: 1))
    }

    func testEachFilterStopsAfterWorkHasStarted() {
        let image = FITSImage.fromFloat32(
            pixels: [Float](repeating: 1, count: 64 * 64), width: 64, height: 64
        )
        let operations: [(() throws -> FITSImage)] = [
            { try ImageFilters.boxcarCheckingCancellation(image, size: 3, checkCancellation: self.stopOnThirdCheck()) },
            { try ImageFilters.medianCheckingCancellation(image, size: 3, checkCancellation: self.stopOnThirdCheck()) },
            { try ImageFilters.gaussianCheckingCancellation(image, sigma: 1, checkCancellation: self.stopOnThirdCheck()) },
        ]
        for operation in operations {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertTrue(error is Stop, "Unexpected error: \(error)")
            }
        }
    }

    func testMedianChecksDuringLargeNeighborhoodSort() {
        let image = FITSImage.fromFloat32(pixels: [1], width: 1, height: 1)
        var checks = 0
        XCTAssertThrowsError(try ImageFilters.medianCheckingCancellation(
            image, size: 19, checkCancellation: {
                checks += 1
                if checks == 4 { throw Stop.requested }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(checks, 4)
    }

    func testLargeMedianNeighborhoodReturnsMiddleValue() throws {
        let pixels = (0..<361).map { Float(($0 * 137) % 361) }
        let image = FITSImage.fromFloat32(pixels: pixels, width: 19, height: 19)
        let result = try ImageFilters.medianCheckingCancellation(image, size: 19)
        XCTAssertEqual(result.physicalValue(x: 9, y: 9), 180)
    }

    func testDefaultCheckObservesTaskCancellation() async {
        let detected = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            let image = FITSImage.fromFloat32(pixels: [1], width: 1, height: 1)
            do {
                _ = try ImageArithmetic.unaryCheckingCancellation(image, op: .negate)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(detected)
    }

    func testFloatNormalizationChecksDuringDecode() {
        let image = FITSImage.fromFloat32(
            pixels: [Float](repeating: 3, count: 20_000), width: 200, height: 100
        )
        XCTAssertThrowsError(try image.normalizedFloat32CheckingCancellation(
            checkCancellation: stopOnThirdCheck()
        )) { XCTAssertTrue($0 is Stop) }
    }

    func testArithmeticMatchesExistingOutputsIncludingNaN() throws {
        let a = FITSImage.fromFloat32(pixels: [2, .nan, 0, -4], width: 2, height: 2)
        let b = FITSImage.fromFloat32(pixels: [4, 1, 0, .nan], width: 2, height: 2)
        try assertSamePixels(ImageArithmetic.unary(a, op: .sqrt),
                             ImageArithmetic.unaryCheckingCancellation(a, op: .sqrt))
        try assertSamePixels(ImageArithmetic.combined(a, b, op: .ratio),
                             ImageArithmetic.combinedCheckingCancellation(a, b, op: .ratio))
        try assertSamePixels(ImageArithmetic.combined(a, b, op: .mask),
                             ImageArithmetic.combinedCheckingCancellation(a, b, op: .mask))
    }

    func testArithmeticStopsAfterWorkHasStarted() {
        let image = FITSImage.fromFloat32(
            pixels: [Float](repeating: 4, count: 4096), width: 64, height: 64
        )
        XCTAssertThrowsError(try ImageArithmetic.unaryCheckingCancellation(
            image, op: .sqrt, checkCancellation: stopOnThirdCheck()
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertThrowsError(try ImageArithmetic.combinedCheckingCancellation(
            image, image, op: .sum, checkCancellation: stopOnThirdCheck()
        )) { XCTAssertTrue($0 is Stop) }
    }

    func testArithmeticDimensionMismatchIsPreserved() {
        let a = FITSImage.fromFloat32(pixels: [1], width: 1, height: 1)
        let b = FITSImage.fromFloat32(pixels: [1, 2], width: 2, height: 1)
        XCTAssertThrowsError(try ImageArithmetic.combinedCheckingCancellation(a, b, op: .sum)) {
            XCTAssertEqual($0 as? ImageArithmetic.ArithmeticError, .dimensionMismatch)
        }
    }

    private func stopOnThirdCheck() -> () throws -> Void {
        var checks = 0
        return {
            checks += 1
            if checks == 3 { throw Stop.requested }
        }
    }

    private func assertSamePixels(
        _ expected: FITSImage, _ actual: @autoclosure () throws -> FITSImage,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let actual = try actual()
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        for y in 0..<expected.height {
            for x in 0..<expected.width {
                let a = expected.physicalValue(x: x, y: y)
                let b = actual.physicalValue(x: x, y: y)
                if a.isNaN {
                    XCTAssertTrue(b.isNaN, "(\(x), \(y))", file: file, line: line)
                } else {
                    XCTAssertEqual(a, b, "(\(x), \(y))", file: file, line: line)
                }
            }
        }
    }
}
