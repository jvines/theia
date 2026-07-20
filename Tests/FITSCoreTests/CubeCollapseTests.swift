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

    private func pad(_ s: String) -> String {
        s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
