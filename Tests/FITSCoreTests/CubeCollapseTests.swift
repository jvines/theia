import XCTest
@testable import FITSCore

final class CubeCollapseTests: XCTestCase {
    // A 2×2×3 cube of float32 values:
    //  plane 0: [[1, 2], [3, 4]]
    //  plane 1: [[5, 6], [7, 8]]
    //  plane 2: [[9, 10], [11, 12]]
    private func cubeHDU() throws -> FITSHDU {
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                  -32"),
            pad("NAXIS   =                    3"),
            pad("NAXIS1  =                    2"),
            pad("NAXIS2  =                    2"),
            pad("NAXIS3  =                    3"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        var data = Data(header.utf8)
        // Plane 0: 1,2,3,4 ; Plane 1: 5..8 ; Plane 2: 9..12 (row-major y-up: bl, br, tl, tr)
        for plane in 0..<3 {
            for cell in 0..<4 {
                let v: Float = Float(plane * 4 + cell + 1)
                let bits = v.bitPattern.bigEndian
                withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
            }
        }
        if data.count % 2880 != 0 {
            data.append(Data(repeating: 0, count: 2880 - data.count % 2880))
        }
        return try FITSFile(data: data).hdus[0]
    }

    func testSumAlongPlaneAxis() throws {
        let hdu = try cubeHDU()
        let collapsed = try FITSImage.collapsed(hdu: hdu, mode: .sum)
        XCTAssertEqual(collapsed.width, 2)
        XCTAssertEqual(collapsed.height, 2)
        // Cell (0,0): 1 + 5 + 9 = 15
        XCTAssertEqual(collapsed.physicalValue(x: 0, y: 0), 15, accuracy: 1e-6)
        // Cell (1,1): 4 + 8 + 12 = 24
        XCTAssertEqual(collapsed.physicalValue(x: 1, y: 1), 24, accuracy: 1e-6)
    }

    func testMeanAlongPlaneAxis() throws {
        let hdu = try cubeHDU()
        let collapsed = try FITSImage.collapsed(hdu: hdu, mode: .mean)
        // Cell (0,0): (1+5+9)/3 = 5
        XCTAssertEqual(collapsed.physicalValue(x: 0, y: 0), 5, accuracy: 1e-6)
        XCTAssertEqual(collapsed.physicalValue(x: 1, y: 1), 8, accuracy: 1e-6)
    }

    func testMedianAlongPlaneAxis() throws {
        let hdu = try cubeHDU()
        let collapsed = try FITSImage.collapsed(hdu: hdu, mode: .median)
        // 3 planes → median is middle value
        XCTAssertEqual(collapsed.physicalValue(x: 0, y: 0), 5)
        XCTAssertEqual(collapsed.physicalValue(x: 1, y: 1), 8)
    }

    func testMaxAlongPlaneAxis() throws {
        let hdu = try cubeHDU()
        let collapsed = try FITSImage.collapsed(hdu: hdu, mode: .max)
        XCTAssertEqual(collapsed.physicalValue(x: 0, y: 0), 9)
        XCTAssertEqual(collapsed.physicalValue(x: 1, y: 1), 12)
    }

    func testCollapseSkipsNaN() throws {
        // Build a 1×1×3 cube with values 2, NaN, 6.
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                  -32"),
            pad("NAXIS   =                    3"),
            pad("NAXIS1  =                    1"),
            pad("NAXIS2  =                    1"),
            pad("NAXIS3  =                    3"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        var data = Data(header.utf8)
        for v in [Float(2), .nan, Float(6)] {
            let bits = v.bitPattern.bigEndian
            withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
        }
        if data.count % 2880 != 0 {
            data.append(Data(repeating: 0, count: 2880 - data.count % 2880))
        }
        let hdu = try FITSFile(data: data).hdus[0]
        let collapsed = try FITSImage.collapsed(hdu: hdu, mode: .mean)
        // NaN skipped → mean of (2, 6) = 4
        XCTAssertEqual(collapsed.physicalValue(x: 0, y: 0), 4, accuracy: 1e-6)
    }

    func testCollapseFailsOnNonCube() throws {
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    2"),
            pad("NAXIS1  =                    1"),
            pad("NAXIS2  =                    1"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        var data = Data(header.utf8)
        data.append(Data(repeating: 0, count: 1))
        if data.count % 2880 != 0 {
            data.append(Data(repeating: 0, count: 2880 - data.count % 2880))
        }
        let hdu = try FITSFile(data: data).hdus[0]
        XCTAssertThrowsError(try FITSImage.collapsed(hdu: hdu, mode: .sum))
    }

    func testCancellableCollapsePreservesAllModesAndNaNRules() throws {
        // Four planes exercise even median, skipped NaNs, and all-NaN output.
        let hdu = try floatCube(width: 3, height: 1, planes: [
            [1, .nan, .nan], [3, 2, .nan], [5, .nan, .nan], [9, 6, .nan],
        ])
        let expectations: [(FITSImage.CollapseMode, Double, Double)] = [
            (.sum, 18, 8), (.mean, 4.5, 4), (.median, 4, 4), (.max, 9, 6),
        ]
        for (mode, first, second) in expectations {
            let result = try FITSImage.collapsedCheckingCancellation(hdu: hdu, mode: mode)
            XCTAssertEqual(result.physicalValue(x: 0, y: 0), first, "\(mode)")
            XCTAssertEqual(result.physicalValue(x: 1, y: 0), second, "\(mode)")
            XCTAssertTrue(result.physicalValue(x: 2, y: 0).isNaN, "\(mode)")
        }
    }

    func testCollapseChecksCancellationDuringDecodeAndAccumulation() throws {
        let hdu = try floatCube(width: 16_384, height: 1, planes: [
            [Float](repeating: 1, count: 16_384),
        ])
        // The fifth callback occurs in decoding; the seventh in accumulation.
        for stopAt in [5, 7] {
            var checks = 0
            XCTAssertThrowsError(try FITSImage.collapsedCheckingCancellation(
                hdu: hdu, mode: .sum, checkCancellation: {
                    checks += 1
                    if checks == stopAt { throw CancellationError() }
                }
            )) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, stopAt)
        }
    }

    func testMedianCollapseCanCancelDuringLargeTileProcessing() throws {
        let hdu = try floatCube(width: 66_000, height: 1, planes: [
            [Float](repeating: 2, count: 66_000),
        ])
        var checks = 0
        XCTAssertThrowsError(try FITSImage.collapsedCheckingCancellation(
            hdu: hdu, mode: .median, checkCancellation: {
                checks += 1
                if checks == 20 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 20)
    }

    func testMedianCollapseProducesValuesAcrossTileBoundary() throws {
        // Two planes give a 32,768-pixel tile; the last pixel is in tile two.
        let hdu = try floatCube(width: 32_769, height: 1, planes: [
            [Float](repeating: 2, count: 32_769),
            [Float](repeating: 6, count: 32_769),
        ])
        let result = try FITSImage.collapsedCheckingCancellation(hdu: hdu, mode: .median)
        XCTAssertEqual(result.physicalValue(x: 0, y: 0), 4)
        XCTAssertEqual(result.physicalValue(x: 32_768, y: 0), 4)
    }

    func testSlabUsesInclusivePlaneRangeAndPreservesNaN() throws {
        let hdu = try floatCube(width: 3, height: 1, planes: [
            [100, .nan, .nan], [1, 2, .nan], [3, .nan, .nan], [200, 4, .nan],
        ])
        let result = try FITSImage.slabCheckingCancellation(hdu: hdu, from: 1, to: 2)
        XCTAssertEqual(result.physicalValue(x: 0, y: 0), 4)
        XCTAssertEqual(result.physicalValue(x: 1, y: 0), 2)
        XCTAssertTrue(result.physicalValue(x: 2, y: 0).isNaN)
    }

    func testSlabRejectsInvalidBounds() throws {
        let hdu = try cubeHDU()
        for (from, to) in [(-1, 1), (0, 3), (2, 1)] {
            XCTAssertThrowsError(try FITSImage.slabCheckingCancellation(
                hdu: hdu, from: from, to: to
            ))
        }
    }

    func testSlabRetainsMacFloatAccumulation() throws {
        let hdu = try floatCube(width: 1, height: 1, planes: [
            [100_000_000], [1], [-100_000_000],
        ])
        // Adding 1 to 100 million is rounded away in Float32.
        let result = try FITSImage.slab(hdu: hdu, from: 0, to: 2)
        XCTAssertEqual(result.physicalValue(x: 0, y: 0), 0)
    }

    func testSlabChecksCancellationWithinWidePlane() throws {
        let hdu = try floatCube(width: 16_384, height: 1, planes: [
            [Float](repeating: 1, count: 16_384),
        ])
        var checks = 0
        XCTAssertThrowsError(try FITSImage.slabCheckingCancellation(
            hdu: hdu, from: 0, to: 0, checkCancellation: {
                checks += 1
                if checks == 3 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 3)
    }

    private func floatCube(width: Int, height: Int, planes: [[Float]]) throws -> FITSHDU {
        precondition(planes.allSatisfy { $0.count == width * height })
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                  -32"),
            pad("NAXIS   =                    3"),
            pad("NAXIS1  = \(String(format: "%20d", width))"),
            pad("NAXIS2  = \(String(format: "%20d", height))"),
            pad("NAXIS3  = \(String(format: "%20d", planes.count))"),
            pad("END"),
        ]
        var header = cards.joined()
        header += String(repeating: " ", count: (2880 - header.count % 2880) % 2880)
        var data = Data(header.utf8)
        for plane in planes {
            for value in plane {
                var bits = value.bitPattern.bigEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
        return try FITSFile(data: data).hdus[0]
    }

    private func pad(_ s: String) -> String {
        s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
