import XCTest
@testable import TheiaKit

final class ContourLevelsModelTests: XCTestCase {
    func testMissingBoundsUseDataRangeAndCountIsClamped() {
        let initial = ContourSpec(enabled: true, count: 40)
        let model = ContourLevelsModel(initial: initial, dataMin: 2, dataMax: 10)
        XCTAssertEqual(model.spec.minValue, 2)
        XCTAssertEqual(model.spec.maxValue, 10)
        XCTAssertEqual(model.spec.count, 32)
        XCTAssertEqual(model.minText, "2.0000")
        XCTAssertEqual(model.maxText, "10.0000")
        XCTAssertEqual(model.previewLevels.count, 32)
    }

    func testCommaDecimalCommitInvalidResetAndUseDataRange() {
        var model = ContourLevelsModel(initial: ContourSpec(enabled: true, count: 3,
                                                            minValue: 1, maxValue: 9),
                                       dataMin: -2, dataMax: 12)
        model.minText = "2,5"
        model.commitMin()
        XCTAssertEqual(model.spec.minValue, 2.5)
        XCTAssertEqual(model.previewLevels, [2.5, 5.75, 9])
        model.maxText = "not a number"
        model.commitMax()
        XCTAssertEqual(model.spec.maxValue, 9)
        XCTAssertEqual(model.maxText, "9.0000")
        model.useDataRange()
        XCTAssertEqual(model.spec.minValue, -2)
        XCTAssertEqual(model.spec.maxValue, 12)
        XCTAssertEqual(model.minText, "-2.0000")
        XCTAssertEqual(model.maxText, "12.0000")
    }

    func testNonFiniteDataDoesNotOverwriteFiniteSelectedBounds() {
        var model = ContourLevelsModel(initial: ContourSpec(minValue: 1, maxValue: 5),
                                       dataMin: .nan, dataMax: .infinity)
        model.useDataRange()
        XCTAssertEqual(model.spec.minValue, 1)
        XCTAssertEqual(model.spec.maxValue, 5)
        XCTAssertEqual(model.previewText, "—")
    }
}
