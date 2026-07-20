import XCTest
@testable import FITSCore

final class FITSAsciiTableTests: XCTestCase {
    func testParsesFixedWidthASCIITable() throws {
        // 3 columns: id (I5 → 5 chars), name (A10 → 10 chars), mag (F8.3 → 8 chars).
        // Row = 5 + 10 + 8 = 23 chars. 2 rows.
        let header = headerBlock([
            "XTENSION= 'TABLE   '           ",
            "BITPIX  =                    8",
            "NAXIS   =                    2",
            "NAXIS1  =                   23",
            "NAXIS2  =                    2",
            "PCOUNT  =                    0",
            "GCOUNT  =                    1",
            "TFIELDS =                    3",
            "TTYPE1  = 'id'                ",
            "TFORM1  = 'I5'                ",
            "TBCOL1  =                    1",
            "TTYPE2  = 'name'              ",
            "TFORM2  = 'A10'               ",
            "TBCOL2  =                    6",
            "TTYPE3  = 'mag'               ",
            "TFORM3  = 'F8.3'              ",
            "TBCOL3  =                   16",
            "TUNIT3  = 'mag'               ",
            "END",
        ])
        var data = Data()
        data.append("   42Star A      15.500".data(using: .ascii)!)
        data.append("  100Galaxy B    20.300".data(using: .ascii)!)
        if data.count % 2880 != 0 {
            data.append(Data(repeating: 0x20, count: 2880 - data.count % 2880))
        }
        let primary = primaryBlock()
        let file = try FITSFile(data: primary + header + data)
        let table = try XCTUnwrap(FITSAsciiTable(hdu: file.hdus[1]))

        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.columns.count, 3)
        XCTAssertEqual(table.columns[0].name, "id")
        XCTAssertEqual(table.columns[0].width, 5)
        XCTAssertEqual(table.columns[2].unit, "mag")

        XCTAssertEqual(table.displayValue(row: 0, column: 0), "42")
        XCTAssertEqual(table.displayValue(row: 0, column: 1), "Star A")
        XCTAssertEqual(table.displayValue(row: 0, column: 2), "15.500")
        XCTAssertEqual(table.displayValue(row: 1, column: 0), "100")
        XCTAssertEqual(table.displayValue(row: 1, column: 1), "Galaxy B")
        XCTAssertEqual(table.displayValue(row: 1, column: 2), "20.300")
    }

    func testReturnsNilForNonAsciiTable() throws {
        let primary = primaryBlock()
        let file = try FITSFile(data: primary)
        XCTAssertNil(FITSAsciiTable(hdu: file.hdus[0]))
    }

    // MARK: - BUG-4: malformed TBCOL must not trap displayValue

    private func singleColumnTable(tbcol: Int) throws -> FITSAsciiTable {
        let header = headerBlock([
            "XTENSION= 'TABLE   '           ",
            "BITPIX  =                    8",
            "NAXIS   =                    2",
            "NAXIS1  =                   10",
            "NAXIS2  =                    1",
            "PCOUNT  =                    0",
            "GCOUNT  =                    1",
            "TFIELDS =                    1",
            "TTYPE1  = 'id'                ",
            "TFORM1  = 'I5'                ",
            "TBCOL1  = " + String(repeating: " ", count: 20 - String(tbcol).count) + String(tbcol),
            "END",
        ])
        var data = Data("   42     ".data(using: .ascii)!)   // 10 bytes = one row
        if data.count % 2880 != 0 { data.append(Data(repeating: 0x20, count: 2880 - data.count % 2880)) }
        let file = try FITSFile(data: primaryBlock() + header + data)
        return try XCTUnwrap(FITSAsciiTable(hdu: file.hdus[1]))
    }

    /// A TBCOL far past the row width makes cellStart > cellEnd, so the raw
    /// `subdata(in: cellStart..<cellEnd)` range traps. Must clamp and return "".
    func testAsciiTableOutOfRangeTBCOLDoesNotTrap() throws {
        let table = try singleColumnTable(tbcol: 9999)
        XCTAssertEqual(table.displayValue(row: 0, column: 0), "")
    }

    /// TBCOL=0 gives startColumn = -1, so cellStart drops below data.startIndex
    /// for row 0 and the subdata range traps. Must guard and return "".
    func testAsciiTableZeroTBCOLDoesNotTrap() throws {
        let table = try singleColumnTable(tbcol: 0)
        XCTAssertEqual(table.displayValue(row: 0, column: 0), "")
    }

    private func primaryBlock() -> Data {
        headerBlock([
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "EXTEND  =                    T",
            "END",
        ])
    }

    private func headerBlock(_ cards: [String]) -> Data {
        var s = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        if s.count % 2880 != 0 {
            s += String(repeating: " ", count: 2880 - s.count % 2880)
        }
        return Data(s.utf8)
    }
}
