import XCTest
import FITSCore
@testable import TheiaKit

final class PixelTableModelTests: XCTestCase {
    func testGridRunsFromHighYToLowYAndPadsOutsideImage() throws {
        let image = FITSImage.fromFloat32(pixels: (0..<9).map(Float.init),
                                           width: 3, height: 3)
        let cursor = CursorInfo(imageX: 0, imageY: 0, value: 0)
        let table = try XCTUnwrap(PixelTableModel(size: 5).snapshot(image: image,
                                                                   cursor: cursor))

        XCTAssertEqual(table.rows.count, 5)
        XCTAssertTrue(table.rows.allSatisfy { $0.count == 5 })
        XCTAssertEqual(table.rows[0][2].y, 2)
        XCTAssertEqual(table.rows[0][2].value, 6)
        XCTAssertEqual(table.rows[2][2].value, 0)
        XCTAssertTrue(table.rows[2][2].isActive)
        XCTAssertTrue(table.rows[0][0].value.isNaN)
        XCTAssertEqual(table.rows[4][2].y, -2)
        XCTAssertTrue(table.rows[4][2].value.isNaN)
        XCTAssertEqual(table.coordinateText, "(x, y) = (1, 1)")
        XCTAssertEqual(table.valueText, "value = 0")
    }

    func testSizeChoicesAndMissingInputs() {
        XCTAssertEqual(PixelTableModel.sizes, [5, 7, 9, 11])
        XCTAssertEqual(PixelTableModel(size: 8).size, 7)
        XCTAssertEqual(PixelTableModel(size: 9).size, 9)
        let image = FITSImage.fromFloat32(pixels: [42], width: 1, height: 1)
        let cursor = CursorInfo(imageX: 0, imageY: 0, value: 42)
        XCTAssertNil(PixelTableModel(size: 5).snapshot(image: nil, cursor: cursor))
        XCTAssertNil(PixelTableModel(size: 5).snapshot(image: image, cursor: nil))
    }

    func testFooterSamplesCurrentImageAfterRevisionChanges() throws {
        let image = FITSImage.fromFloat32(pixels: [42], width: 1, height: 1)
        let staleCursor = CursorInfo(imageX: 0, imageY: 0, value: 1)
        let table = try XCTUnwrap(PixelTableModel(size: 5).snapshot(image: image,
                                                                   cursor: staleCursor))
        XCTAssertEqual(table.rows[2][2].value, 42)
        XCTAssertEqual(table.valueText, "value = 42")
    }
}
