import XCTest
import FITSCore
@testable import TheiaKit

final class CircularProfileModelTests: XCTestCase {
    private func image(_ value: Float = 1) -> FITSImage {
        FITSImage.fromFloat32(pixels: [Float](repeating: value, count: 121), width: 11, height: 11)
    }

    func testRadialParametersClampAndRecomputePlotOffMainActor() async {
        let model = await MainActor.run {
            RadialProfileModel(image: image(), center: SIMD2(5, 5), initialRadius: 4)
        }
        await model.idle()
        await MainActor.run {
            XCTAssertEqual(model.maxAllowedRadius, 11)
            XCTAssertEqual(model.radius, 4)
            XCTAssertEqual(model.binWidth, 1)
            XCTAssertEqual(model.xValues.first, 0.5)
            XCTAssertEqual(model.yValues.first, 1)
            model.setRadius(100)
            model.setBinWidth(0.1)
        }
        await model.idle()
        await MainActor.run {
            XCTAssertEqual(model.radius, 11)
            XCTAssertEqual(model.binWidth, 0.5)
            XCTAssertEqual(model.yValues.first, 1)
            model.setRadius(.nan)
            model.setBinWidth(.infinity)
            XCTAssertEqual(model.radius, 11)
            XCTAssertEqual(model.binWidth, 0.5)
        }
    }

    func testGrowthParametersClampAndRecomputeLatestValues() async {
        let model = await MainActor.run {
            GrowthCurveModel(image: image(), center: SIMD2(5, 5), initialRadius: 4)
        }
        await MainActor.run {
            model.setRadius(8)
            model.setStep(2)
            model.setRadius(6)
        }
        await model.idle()
        await MainActor.run {
            XCTAssertEqual(model.radius, 6)
            XCTAssertEqual(model.step, 2)
            XCTAssertEqual(model.xValues, [2, 4, 6])
            XCTAssertEqual(model.yValues.last, 109)
            model.setStep(100)
            XCTAssertEqual(model.step, 10)
        }
    }

    func testInvalidAndDistantCenterProduceEmptyData() async {
        let far = await MainActor.run {
            GrowthCurveModel(image: image(), center: SIMD2(100, 100), initialRadius: 3)
        }
        let invalid = await MainActor.run {
            RadialProfileModel(image: image(), center: SIMD2(.nan, 5), initialRadius: 3)
        }
        await far.idle()
        await invalid.idle()
        await MainActor.run {
            XCTAssertTrue(far.yValues.allSatisfy { $0 == 0 })
            XCTAssertTrue(invalid.yValues.isEmpty)
        }
    }

    func testCancelDiscardsPendingWorkWhenPanelCloses() async {
        let radial = await MainActor.run {
            RadialProfileModel(image: image(), center: SIMD2(5, 5), initialRadius: 4)
        }
        let growth = await MainActor.run {
            GrowthCurveModel(image: image(), center: SIMD2(5, 5), initialRadius: 4)
        }
        await MainActor.run {
            radial.cancel()
            growth.cancel()
        }
        await radial.idle()
        await growth.idle()
        await MainActor.run {
            XCTAssertFalse(radial.isComputing)
            XCTAssertFalse(growth.isComputing)
            XCTAssertTrue(radial.xValues.isEmpty)
            XCTAssertTrue(growth.xValues.isEmpty)
        }
    }
}
