import XCTest
@testable import FITSCore

final class FITSHeaderTests: XCTestCase {
    func testParsesMinimalPrimaryHeader() throws {
        let header = makeHeader([
            "SIMPLE  =                    T / file conforms to FITS standard",
            "BITPIX  =                  -32 / 32-bit float",
            "NAXIS   =                    2",
            "NAXIS1  =                  100",
            "NAXIS2  =                   50",
            "END",
        ])
        let data = Data(header.utf8)
        let result = try FITSHeader.parse(in: data, at: 0)
        XCTAssertNotNil(result)
        let parsed = result!.0
        XCTAssertEqual(parsed["BITPIX"]?.intValue, -32)
        XCTAssertEqual(parsed["NAXIS"]?.intValue, 2)
        XCTAssertEqual(parsed["NAXIS1"]?.intValue, 100)
        XCTAssertEqual(parsed["NAXIS2"]?.intValue, 50)
    }

    func testParsesStringValueWithEscapedQuote() throws {
        let header = makeHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "OBJECT  = 'O''Hara field'      / target name",
            "END",
        ])
        let data = Data(header.utf8)
        let result = try FITSHeader.parse(in: data, at: 0)
        XCTAssertEqual(result?.0["OBJECT"]?.stringValue, "O'Hara field")
    }

    // MARK: - BUG-6: HIERARCH (ESO) cards

    func testParsesHierarchESOCards() throws {
        let header = makeHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "HIERARCH ESO DET DIT = 3.5 / Detector integration time",
            "HIERARCH ESO INS MODE = 'HARPS' / Instrument mode",
            "END",
        ])
        let parsed = try XCTUnwrap(FITSHeader.parse(in: Data(header.utf8), at: 0)).0
        XCTAssertEqual(parsed["ESO DET DIT"]?.doubleValue, 3.5)
        XCTAssertEqual(parsed.cards.first(where: { $0.keyword == "ESO DET DIT" })?.comment,
                       "Detector integration time")
        XCTAssertEqual(parsed["ESO INS MODE"]?.stringValue, "HARPS")
    }

    func testHierarchCardRoundTripsThroughSerializer() throws {
        // Editing + saving a HIERARCH card must reproduce a HIERARCH line rather
        // than being dropped (serializeCard previously rejected keys > 8 chars).
        let line = try XCTUnwrap(FITSHeader.serializeCard(
            keyword: "ESO DET DIT", valueText: "3.5", commentText: "Detector integration time"))
        XCTAssertTrue(line.hasPrefix("HIERARCH ESO DET DIT = "), "got: \(line)")
        let reparsed = try XCTUnwrap(FITSHeader.parse(in: Data(makeHeader([
            "SIMPLE  =                    T",
            "NAXIS   =                    0",
            line.trimmingCharacters(in: .whitespaces),
            "END",
        ]).utf8), at: 0)).0
        XCTAssertEqual(reparsed["ESO DET DIT"]?.doubleValue, 3.5)
    }

    // MARK: - BUG-9: CONTINUE long-string assembly

    func testAssemblesCONTINUELongString() throws {
        let header = makeHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "LONGSTR = 'first part of the string &'",
            "CONTINUE  'second part.'",
            "END",
        ])
        let parsed = try XCTUnwrap(FITSHeader.parse(in: Data(header.utf8), at: 0)).0
        XCTAssertEqual(parsed["LONGSTR"]?.stringValue, "first part of the string second part.")
        XCTAssertNil(parsed.cards.first(where: { $0.keyword == "CONTINUE" }),
                     "CONTINUE must be merged into the preceding string, not left as an orphan card")
    }

    // MARK: - BUG-11: a blank-keyword card containing "END" must not end the header

    func testBlankKeywordENDDoesNotTerminateHeaderEarly() throws {
        let header = makeHeader([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "        END",              // blank keyword field, "END" only in the body
            "OBJECT  = 'M31'",
            "END",
        ])
        let parsed = try XCTUnwrap(FITSHeader.parse(in: Data(header.utf8), at: 0)).0
        XCTAssertEqual(parsed["OBJECT"]?.stringValue, "M31",
                       "a card after a fake-END card must still be parsed")
    }

    /// Build an 80-char-card, 2880-padded header block.
    private func makeHeader(_ cards: [String]) -> String {
        var out = ""
        for card in cards {
            let padded = card.padding(toLength: 80, withPad: " ", startingAt: 0)
            out += padded
        }
        // pad block
        let blockSize = 2880
        let remainder = out.count % blockSize
        if remainder != 0 {
            out += String(repeating: " ", count: blockSize - remainder)
        }
        return out
    }
}
