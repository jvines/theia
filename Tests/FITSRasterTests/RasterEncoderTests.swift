import Foundation
import XCTest
import FITSCore
import CZlib
@testable import FITSRaster

final class RasterEncoderTests: XCTestCase {
    private let colors: [UInt8] = [
        1, 2, 3, 255, 4, 5, 6, 255,
        7, 8, 9, 255, 10, 11, 12, 255,
    ]

    func testPNGRoundTripPreservesTopDownRGBA() throws {
        let raster = RasterImage(width: 2, height: 2, bytes: colors)
        let encoded = try RasterEncoder.png(raster)
        XCTAssertEqual(Array(encoded.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(Array(encoded[12..<16]), Array("IHDR".utf8))
        XCTAssertEqual(Array(encoded[16..<24]), [0, 0, 0, 2, 0, 0, 0, 2])
        let idatLength = Int(encoded[33]) << 24 | Int(encoded[34]) << 16 | Int(encoded[35]) << 8 | Int(encoded[36])
        XCTAssertEqual(Array(encoded[37..<41]), Array("IDAT".utf8))
        let compressed = Array(encoded[41..<(41 + idatLength)])
        var raw = [UInt8](repeating: 0, count: 18)
        var rawLength = uLongf(raw.count)
        let status = compressed.withUnsafeBufferPointer { source in
            raw.withUnsafeMutableBufferPointer { dest in
                uncompress(dest.baseAddress, &rawLength, source.baseAddress, uLong(source.count))
            }
        }
        XCTAssertEqual(status, Z_OK)
        XCTAssertEqual(rawLength, 18)
        XCTAssertEqual(Array(raw[0..<9]), [0] + Array(colors[0..<8]))
        XCTAssertEqual(Array(raw[9..<18]), [0] + Array(colors[8..<16]))
    }

    func testTIFFCarriesDimensionsAndTopDownRGBA() throws {
        let raster = RasterImage(width: 2, height: 2, bytes: colors)
        let encoded = try RasterEncoder.tiff(raster)
        XCTAssertEqual(Array(encoded.prefix(8)), [73, 73, 42, 0, 8, 0, 0, 0])
        func word(_ offset: Int) -> Int { Int(encoded[offset]) | Int(encoded[offset + 1]) << 8 }
        func long(_ offset: Int) -> Int { word(offset) | word(offset + 2) << 16 }
        let tagCount = word(8)
        XCTAssertEqual(tagCount, 11)
        var tags: [Int: Int] = [:]
        for i in 0..<tagCount {
            let offset = 10 + i * 12
            tags[word(offset)] = long(offset + 8)
        }
        XCTAssertEqual(tags[256], 2)
        XCTAssertEqual(tags[257], 2)
        XCTAssertEqual(tags[277], 4)
        XCTAssertEqual(tags[279], colors.count)
        XCTAssertEqual(Array(encoded[tags[273]!..<(tags[273]! + colors.count)]), colors)
    }
}
