import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class SessionStateTests: XCTestCase {
    func testTypedDrawModeRoundTripsWithLegacyJSONValue() throws {
        let state = SessionState(
            selectedHDU: 2, selectedPlane: 4, stretch: .asinh, colorMap: .magma,
            drawMode: .drawBox, vmin: 1.5, vmax: 99.5, stretchParameter: 1.8,
            showWCSGrid: true, showCompass: false, showColorBar: true,
            regions: [
                Region(
                    shape: .circle(center: .init(x: 10, y: 20), radius: .init(value: 5, unit: .pixel)),
                    frame: .image
                ),
                Region(
                    shape: .annulus(center: .init(x: 30, y: 40),
                                    innerRadius: .init(value: 1, unit: .arcsecond),
                                    outerRadius: .init(value: 3, unit: .arcsecond)),
                    frame: .fk5
                ),
            ], contour: SessionState.Contour(
                enabled: true, count: 7, minValue: 0.1, maxValue: 0.9, spacing: "log"
            )
        )
        let json = try state.toJSON()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["drawMode"] as? String, "drawBox")
        XCTAssertEqual(object["selectedHDU"] as? Int, 2)
        XCTAssertEqual(try SessionState.fromJSON(json), state)
    }

    func testLegacySidecarWithoutOptionalContourDecodesIntoTypedMode() throws {
        let legacy = """
        {
            "selectedHDU": 0,
            "selectedPlane": 0,
            "stretch": "linear",
            "colorMap": "gray",
            "drawMode": "lineProfile",
            "vmin": 0,
            "vmax": 1,
            "stretchParameter": 2,
            "showWCSGrid": false,
            "showCompass": false,
            "showColorBar": false,
            "regions": []
        }
        """
        let state = try SessionState.fromJSON(Data(legacy.utf8))
        XCTAssertEqual(state.drawMode, .lineProfile)
        XCTAssertNil(state.contour)
        XCTAssertEqual(try SessionState.fromJSON(state.toJSON()), state)
    }

    func testUnknownDrawModeKeepsOtherSavedFieldsAndFallsBackToPan() throws {
        let legacy = """
        {
            "selectedHDU": 3,
            "selectedPlane": 0,
            "stretch": "linear",
            "colorMap": "gray",
            "drawMode": "futureTool",
            "vmin": 12,
            "vmax": 80,
            "stretchParameter": 2,
            "showWCSGrid": true,
            "showCompass": false,
            "showColorBar": false,
            "regions": []
        }
        """
        let state = try SessionState.fromJSON(Data(legacy.utf8))
        XCTAssertEqual(state.drawMode, .pan)
        XCTAssertEqual(state.selectedHDU, 3)
        XCTAssertEqual(state.vmin, 12)
        XCTAssertTrue(state.showWCSGrid)
    }

    func testSidecarPathAppendsExtension() {
        let url = URL(fileURLWithPath: "/tmp/test.fits")
        XCTAssertEqual(SessionState.sidecarURL(for: url).path, "/tmp/test.fits.session.json")
    }
}
