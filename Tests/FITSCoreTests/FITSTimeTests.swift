import Foundation
import XCTest
@testable import FITSCore

final class FITSTimeTests: XCTestCase {
    func testBJDHasPriorityAndConvertsToMJDScale() throws {
        let header = try makeHeader([
            card("BJD-OBS", "2451545.0"),
            card("MJD-OBS", "59000.0"),
            card("JD-OBS", "2450000.0"),
        ])
        let time = try XCTUnwrap(FITSTime.observationMJD(header: header))
        XCTAssertEqual(time.mjd, 51544.5, accuracy: 1e-9)
        XCTAssertEqual(time.label, "BJD-2400000.5")
    }

    func testMJDHasPriorityOverJDAndDate() throws {
        let header = try makeHeader([
            card("MJD-OBS", "59000.25"),
            card("JD-OBS", "2450000.0"),
            card("DATE-OBS", "'1970-01-01'"),
        ])
        let time = try XCTUnwrap(FITSTime.observationMJD(header: header))
        XCTAssertEqual(time.mjd, 59000.25, accuracy: 1e-9)
        XCTAssertEqual(time.label, "MJD")
    }

    func testJDConvertsToMJDScale() throws {
        let header = try makeHeader([card("JD-OBS", "2440587.5")])
        let time = try XCTUnwrap(FITSTime.observationMJD(header: header))
        XCTAssertEqual(time.mjd, 40587, accuracy: 1e-9)
        XCTAssertEqual(time.label, "JD-2400000.5")
    }

    func testDateOnlyDefaultsToMidnightUTC() throws {
        let header = try makeHeader([card("DATE-OBS", "'1970-01-01'")])
        let time = try XCTUnwrap(FITSTime.observationMJD(header: header))
        XCTAssertEqual(time.mjd, 40587, accuracy: 1e-9)
        XCTAssertEqual(time.label, "MJD")
    }

    func testSeparateFractionalTimeCardAugmentsDate() throws {
        let header = try makeHeader([
            card("DATE-OBS", "'1970-01-01'"),
            card("TIME-OBS", "'12:00:00.000'"),
        ])
        let time = try XCTUnwrap(FITSTime.observationMJD(header: header))
        XCTAssertEqual(time.mjd, 40587.5, accuracy: 1e-9)
    }

    func testInvalidOrMissingTimeReturnsNil() throws {
        XCTAssertNil(FITSTime.observationMJD(header: try makeHeader([])))
        XCTAssertNil(FITSTime.observationMJD(header: try makeHeader([
            card("DATE-OBS", "'not-a-date'"),
        ])))
    }

    private func card(_ keyword: String, _ value: String) -> String {
        "\(keyword.padding(toLength: 8, withPad: " ", startingAt: 0))= \(value)"
    }

    private func makeHeader(_ values: [String]) throws -> FITSHeader {
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
        ] + values + ["END"]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let padding = (2880 - text.utf8.count % 2880) % 2880
        text += String(repeating: " ", count: padding)
        return try XCTUnwrap(FITSHeader.parse(in: Data(text.utf8), at: 0)).0
    }
}
