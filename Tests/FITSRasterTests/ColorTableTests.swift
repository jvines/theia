import XCTest
import FITSCore
@testable import FITSRaster

final class ColorTableTests: XCTestCase {
    func testAllMapsUseSmallestPowerOfTwoWithOneLSBError() {
        for map in ColorMap.allCases {
            let table = ColorTable(map: map)
            XCTAssertGreaterThanOrEqual(table.entries.count, 2)
            XCTAssertEqual(table.entries.count & (table.entries.count - 1), 0)
            for i in 1..<table.entries.count {
                let a = table.entries[i - 1], b = table.entries[i]
                XCTAssertLessThanOrEqual(abs(Int(a.r) - Int(b.r)), 1)
                XCTAssertLessThanOrEqual(abs(Int(a.g) - Int(b.g)), 1)
                XCTAssertLessThanOrEqual(abs(Int(a.b) - Int(b.b)), 1)
            }
            for i in 0...16384 {
                let t = Float(i) / 16384
                let actual = table.color(for: t)
                let reference = RGBA8(map.sample(t))
                XCTAssertLessThanOrEqual(abs(Int(actual.r) - Int(reference.r)), 1)
                XCTAssertLessThanOrEqual(abs(Int(actual.g) - Int(reference.g)), 1)
                XCTAssertLessThanOrEqual(abs(Int(actual.b) - Int(reference.b)), 1)
            }
        }
    }

    func testLookupRoundsToNearestEntry() {
        let table = ColorTable(map: .gray)
        XCTAssertEqual(table.color(for: -.infinity), table.entries.first)
        XCTAssertEqual(table.color(for: .infinity), table.entries.last)
        XCTAssertEqual(table.color(for: .nan), .opaqueBlack)
        let midpoint = Float(0.5) / Float(table.entries.count - 1)
        XCTAssertEqual(table.color(for: midpoint), table.entries[1])
    }
}
