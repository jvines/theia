import XCTest
import FITSCore
@testable import TheiaKit

final class RegionListTests: XCTestCase {
    private func point(_ x: Double, _ y: Double) -> Region {
        Region(shape: .point(.init(x: x, y: y)), frame: .image)
    }

    func testDragUpdatesCommitAsOneUndoStepAndRedoRestoresSelection() throws {
        var list = RegionList()
        let original = point(1, 2)
        list.add(original)
        XCTAssertTrue(list.beginEdit(at: 0))
        let drag = try XCTUnwrap(list.activeEditID)
        XCTAssertTrue(list.updateDuringEdit(drag, at: 0, with: point(2, 2)))
        XCTAssertTrue(list.updateDuringEdit(drag, at: 0, with: point(3, 2)))
        XCTAssertTrue(list.commitEdit(drag))
        XCTAssertEqual(list.regions, [point(3, 2)])
        XCTAssertTrue(list.undo())
        XCTAssertEqual(list.regions, [original])
        XCTAssertEqual(list.selectedIndex, 0)
        XCTAssertTrue(list.redo())
        XCTAssertEqual(list.regions, [point(3, 2)])
        XCTAssertEqual(list.selectedIndex, 0)
        XCTAssertTrue(list.undo())
        XCTAssertTrue(list.undo())
        XCTAssertTrue(list.regions.isEmpty)
    }

    func testCancelAndBatchReplaceHavePredictableHistory() throws {
        var list = RegionList()
        list.replace([point(1, 1), point(2, 2)], selection: 1)
        XCTAssertTrue(list.beginEdit(at: 1))
        let drag = try XCTUnwrap(list.activeEditID)
        XCTAssertTrue(list.updateDuringEdit(drag, at: 1, with: point(8, 8)))
        XCTAssertTrue(list.cancelEdit(drag))
        XCTAssertEqual(list.regions, [point(1, 1), point(2, 2)])
        XCTAssertEqual(list.selectedIndex, 1)

        list.replace([point(4, 4)], selection: nil)
        XCTAssertTrue(list.undo())
        XCTAssertEqual(list.regions, [point(1, 1), point(2, 2)])
        XCTAssertEqual(list.selectedIndex, 1)
        XCTAssertTrue(list.redo())
        XCTAssertEqual(list.regions, [point(4, 4)])
        list.add(point(5, 5))
        XCTAssertFalse(list.canRedo)
    }

    func testReplacementInvalidatesAnInFlightDrag() throws {
        var list = RegionList()
        list.add(point(1, 1))
        XCTAssertTrue(list.beginEdit(at: 0))
        let drag = try XCTUnwrap(list.activeEditID)
        XCTAssertTrue(list.updateDuringEdit(drag, at: 0, with: point(2, 2)))
        list.replace([point(9, 9)], selection: nil)
        XCTAssertFalse(list.updateDuringEdit(drag, at: 0, with: point(3, 3)))
        XCTAssertEqual(list.regions, [point(9, 9)])
        XCTAssertFalse(list.commitEdit(drag))
        XCTAssertTrue(list.undo())
        XCTAssertEqual(list.regions, [point(2, 2)])
        XCTAssertTrue(list.undo())
        XCTAssertEqual(list.regions, [point(1, 1)])
    }
}
