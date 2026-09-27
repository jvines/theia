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

    func testEditorRowsExposeShapeFieldsAndPreserveDistanceUnitsWhenEdited() throws {
        let region = Region(
            shape: .box(
                center: .init(x: 12, y: 34),
                width: .init(value: 5, unit: .arcminute),
                height: .init(value: 6, unit: .arcsecond),
                angle: 7
            ),
            frame: .fk5,
            attributes: ["tag": "target"]
        )
        XCTAssertEqual(RegionList.editorRows(for: region), [
            .coordinates(label: "center", x: 12, y: 34, xField: .centerX, yField: .centerY),
            .distance(label: "width", value: 5, unit: .arcminute, field: .width),
            .distance(label: "height", value: 6, unit: .arcsecond, field: .height),
            .angle(value: 7, field: .angle)
        ])
        let changed = try XCTUnwrap(RegionList.setting(.width, to: 9, in: region))
        XCTAssertEqual(changed.shape, .box(
            center: .init(x: 12, y: 34),
            width: .init(value: 9, unit: .arcminute),
            height: .init(value: 6, unit: .arcsecond),
            angle: 7
        ))
        XCTAssertEqual(changed.frame, .fk5)
        XCTAssertEqual(changed.attributes, ["tag": "target"])
        XCTAssertNil(RegionList.setting(.radius, to: 9, in: region))
    }

    func testPolygonVertexAndPointFieldsRejectWrongIndices() throws {
        let polygon = Region(
            shape: .polygon(points: [.init(x: 1, y: 2), .init(x: 3, y: 4)]),
            frame: .image
        )
        XCTAssertEqual(RegionList.editorRows(for: polygon), [
            .coordinates(label: "v0", x: 1, y: 2, xField: .vertexX(0), yField: .vertexY(0)),
            .coordinates(label: "v1", x: 3, y: 4, xField: .vertexX(1), yField: .vertexY(1))
        ])
        XCTAssertEqual(
            RegionList.setting(.vertexY(1), to: 8, in: polygon)?.shape,
            .polygon(points: [.init(x: 1, y: 2), .init(x: 3, y: 8)])
        )
        XCTAssertNil(RegionList.setting(.vertexX(2), to: 8, in: polygon))
        XCTAssertEqual(RegionList.editorRows(for: point(5, 6)), [
            .coordinates(label: "pos", x: 5, y: 6, xField: .pointX, yField: .pointY)
        ])
    }

    func testRegionAttributesUseSharedPaletteAndEmptyLabelsRemoveKeys() {
        let region = Region(shape: .point(.init(x: 1, y: 2)), frame: .image,
                            attributes: ["text": "old", "tag": "group", "custom": "keep"])
        XCTAssertEqual(RegionList.colors,
                       ["green", "red", "yellow", "cyan", "magenta", "blue", "white", "black"])
        XCTAssertEqual(RegionList.color("violet"), "green")
        XCTAssertEqual(RegionList.color("BLUE"), "blue")
        XCTAssertEqual(RegionList.color("black"), "black")
        XCTAssertEqual(RegionList.attribute(.color, in: region), "green")
        let custom = Region(shape: region.shape, frame: region.frame,
                            attributes: ["color": "#8040c0"])
        XCTAssertEqual(RegionList.attribute(.color, in: custom), "#8040c0")
        let relabeled = RegionList.settingAttribute(.label, to: "", in: region)
        XCTAssertNil(relabeled.attributes["text"])
        XCTAssertEqual(relabeled.attributes["tag"], "group")
        XCTAssertEqual(relabeled.attributes["custom"], "keep")
        let retagged = RegionList.settingAttribute(.tag, to: "", in: relabeled)
        XCTAssertNil(retagged.attributes["tag"])
        XCTAssertEqual(RegionList.settingAttribute(.color, to: "red", in: retagged).attributes["color"], "red")
    }

    func testRegionSummaryAndEditorUnitsMatchTheExistingDisplay() {
        let circle = Region(shape: .circle(center: .init(x: 12.34, y: 45.67),
                                           radius: .init(value: 3.25, unit: .arcsecond)), frame: .fk5)
        let annulus = Region(shape: .annulus(center: .init(x: 1, y: 2),
                                             innerRadius: .init(value: 3, unit: .pixel),
                                             outerRadius: .init(value: 4, unit: .pixel)), frame: .image)
        XCTAssertEqual(RegionList.summary(for: circle), "circle (12.3, 45.7) r=3.2")
        XCTAssertEqual(RegionList.summary(for: annulus), "annulus (1.0, 2.0) 3.0…4.0")
        XCTAssertEqual(RegionList.summary(for: point(5, 6)), "point (5.0, 6.0)")
        XCTAssertEqual(RegionList.unitLabel(.pixel), "px")
        XCTAssertEqual(RegionList.unitLabel(.degree), "°")
        XCTAssertEqual(RegionList.unitLabel(.arcminute), "′")
        XCTAssertEqual(RegionList.unitLabel(.arcsecond), "″")
        XCTAssertEqual(RegionList.editorNumber(12), "12")
        XCTAssertEqual(RegionList.editorNumber(123.456), "123.5")
    }
}
