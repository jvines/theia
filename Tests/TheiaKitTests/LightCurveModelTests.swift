import XCTest
@testable import TheiaKit

final class LightCurveModelTests: XCTestCase {
    func testNormalizesFluxAndErrorBySignedMedianMagnitude() {
        let points = [
            LightCurvePoint(time: 1, flux: -4, err: 2),
            LightCurvePoint(time: 2, flux: -2, err: 1),
            LightCurvePoint(time: 3, flux: -1, err: 0.5),
        ]
        var model = LightCurveModel(points: points, timeLabel: "MJD")
        XCTAssertEqual(model.displayedPoints, points)
        model.normalized = true
        XCTAssertEqual(model.displayedPoints.map(\.flux), [2, 1, 0.5])
        XCTAssertEqual(model.displayedPoints.map(\.err), [1, 0.5, 0.25])
        XCTAssertEqual(model.yLabel, "flux / median")
        XCTAssertEqual(model.csv, "time,flux,err\n1.0,-4.0,2.0\n2.0,-2.0,1.0\n3.0,-1.0,0.5")
    }

    func testZeroOrMissingFiniteMedianKeepsRawPoints() {
        let zero = [LightCurvePoint(time: 1, flux: -1, err: 2),
                    LightCurvePoint(time: 2, flux: 0, err: 3),
                    LightCurvePoint(time: 3, flux: 1, err: 4)]
        var model = LightCurveModel(points: zero, timeLabel: "plane", normalized: true)
        XCTAssertEqual(model.displayedPoints, zero)
        model = LightCurveModel(points: [LightCurvePoint(time: 0, flux: .nan, err: 2)],
                                timeLabel: "plane", normalized: true)
        XCTAssertTrue(model.displayedPoints[0].flux.isNaN)
        XCTAssertEqual(model.displayedPoints[0].err, 2)
    }
}
