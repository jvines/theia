import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class HeaderEditorTests: XCTestCase {
    func testEditsAtSameCardIndexStayWithTheirHDU() async throws {
        let first = try header("EXPTIME =                 10.0 / exposure", "OBJECT  = 'M31' / target")
        let second = try header("FILTER  = 'Ha' / band", "OBJECT  = 'M42' / target")
        await MainActor.run {
            let editor = HeaderEditor()
            editor.setValue("20", for: first.cards[3], at: 3, hdu: 0)
            XCTAssertEqual(editor.valueText(for: first.cards[3], at: 3, hdu: 0), "20")
            XCTAssertTrue(editor.hasEdit(at: 3, hdu: 0))
            XCTAssertFalse(editor.hasEdit(at: 3, hdu: 1))
            XCTAssertEqual(editor.valueText(for: second.cards[3], at: 3, hdu: 1), "Ha")
            XCTAssertEqual(editor.editCount(for: 0), 1)
            XCTAssertEqual(editor.editCount(for: 1), 0)
            XCTAssertTrue(editor.serializedExtraCards(from: first, hdu: 0).contains {
                $0.contains("EXPTIME") && $0.contains("20")
            })
            XCTAssertFalse(editor.serializedExtraCards(from: second, hdu: 1).contains {
                $0.contains("20")
            })

            editor.setComment("updated band", for: second.cards[3], at: 3, hdu: 1)
            XCTAssertEqual(editor.commentText(for: second.cards[3], at: 3, hdu: 1), "updated band")
            editor.clearEdits(for: 0)
            XCTAssertEqual(editor.valueText(for: first.cards[3], at: 3, hdu: 0), "10.0")
            XCTAssertEqual(editor.editCount(for: 1), 1)
        }
    }

    func testFilteringAndSerializationUseSelectedHeadersCards() async throws {
        let source = try header("EXPTIME =                 10.0 / exposure", "OBJECT  = 'M31' / target")
        await MainActor.run {
            let editor = HeaderEditor()
            editor.search = "target"
            XCTAssertEqual(editor.filteredRows(in: source).map(\.card.keyword), ["OBJECT"])
            editor.search = "m31"
            XCTAssertEqual(editor.filteredRows(in: source).map(\.card.keyword), ["OBJECT"])
            editor.search = "exp"
            XCTAssertEqual(editor.filteredRows(in: source).map(\.card.keyword), ["EXPTIME"])

            editor.setValue("21", for: source.cards[3], at: 3, hdu: 0)
            let extra = editor.serializedExtraCards(from: source, hdu: 0)
            XCTAssertEqual(extra.count, 2)
            XCTAssertTrue(extra[0].contains("21"))
            XCTAssertFalse(extra.contains { $0.hasPrefix("SIMPLE") || $0.hasPrefix("NAXIS") })
        }
    }

    private func header(_ extra: String...) throws -> FITSHeader {
        let cards = ["SIMPLE  =                    T", "BITPIX  =                    8",
                     "NAXIS   =                    0"] + extra + ["END"]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        return try FITSFile(data: Data(text.utf8)).hdus[0].header
    }
}
