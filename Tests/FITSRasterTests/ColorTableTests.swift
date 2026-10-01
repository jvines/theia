import XCTest
import FITSCore
@testable import FITSRaster

final class ColorTableTests: XCTestCase {
    func testSteppedMapsKeepEveryBandAtItsDS9Position() {
        for map in ColorMap.allCases where map.hasDiscontinuities {
            let table = ColorTable(map: map)
            XCTAssertEqual(table.entries.count, ColorTable.steppedMapSize, "\(map)")
            // Away from the steps the table is exact; a step lands within
            // half an entry of the map's position.
            let step = 1 / Float(table.entries.count - 1)
            for i in 0...16384 {
                let t = Float(i) / 16384
                let before = RGBA8(map.sample(max(0, t - step)))
                let after = RGBA8(map.sample(min(1, t + step)))
                guard before == after else { continue }
                XCTAssertEqual(table.color(for: t), RGBA8(map.sample(t)), "\(map) t=\(t)")
            }
        }
    }

    func testSmoothMapsUseSmallestPowerOfTwoWithOneLSBError() {
        for map in ColorMap.allCases where !map.hasDiscontinuities {
            let table = ColorTable(map: map)
            XCTAssertGreaterThanOrEqual(table.entries.count, 2)
            XCTAssertEqual(table.entries.count & (table.entries.count - 1), 0)
            for i in 1..<table.entries.count {
                let a = table.entries[i - 1], b = table.entries[i]
                XCTAssertLessThanOrEqual(abs(Int(a.r) - Int(b.r)), 1, "\(map) size=\(table.entries.count) i=\(i)")
                XCTAssertLessThanOrEqual(abs(Int(a.g) - Int(b.g)), 1, "\(map) size=\(table.entries.count) i=\(i)")
                XCTAssertLessThanOrEqual(abs(Int(a.b) - Int(b.b)), 1, "\(map) size=\(table.entries.count) i=\(i)")
            }
            for i in 0...16384 {
                let t = Float(i) / 16384
                let actual = table.color(for: t)
                let reference = RGBA8(map.sample(t))
                XCTAssertLessThanOrEqual(abs(Int(actual.r) - Int(reference.r)), 1, "\(map) i=\(i)")
                XCTAssertLessThanOrEqual(abs(Int(actual.g) - Int(reference.g)), 1, "\(map) i=\(i)")
                XCTAssertLessThanOrEqual(abs(Int(actual.b) - Int(reference.b)), 1, "\(map) i=\(i)")
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
