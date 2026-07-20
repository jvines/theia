import XCTest
@testable import FITSCore

final class SessionStateTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let original = SessionState(
            selectedHDU: 2,
            selectedPlane: 4,
            stretch: .asinh,
            colorMap: .magma,
            drawMode: "drawBox",
            vmin: 1.5,
            vmax: 99.5,
            stretchParameter: 1.8,
            showWCSGrid: true,
            showCompass: false,
            showColorBar: true,
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
            ],
            contour: SessionState.Contour(enabled: true, count: 7, minValue: 0.1, maxValue: 0.9, spacing: "log")
        )
        let data = try original.toJSON()
        let restored = try SessionState.fromJSON(data)
        XCTAssertEqual(restored, original)
    }

    func testHandlesMissingOptionalKeys() throws {
        // Forward-compat: an older session file without `contour` still parses.
        let json = """
        {
            "selectedHDU": 0,
            "selectedPlane": 0,
            "stretch": "linear",
            "colorMap": "gray",
            "drawMode": "pan",
            "vmin": 0,
            "vmax": 1,
            "stretchParameter": 2,
            "showWCSGrid": false,
            "showCompass": false,
            "showColorBar": false,
            "regions": []
        }
        """
        let s = try SessionState.fromJSON(Data(json.utf8))
        XCTAssertEqual(s.regions.count, 0)
        XCTAssertNil(s.contour)
    }

    func testSidecarPathAppendsExtension() {
        let url = URL(fileURLWithPath: "/tmp/test.fits")
        XCTAssertEqual(SessionState.sidecarURL(for: url).path, "/tmp/test.fits.session.json")
    }
}
