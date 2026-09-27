import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class XPACommandMapperTests: XCTestCase {
    func testGetUsesDocumentSnapshotAndDS9Names() {
        let snapshot = XPADocumentSnapshot(id: 4, path: "/data/star.fits",
                                           stretch: .power, colorMap: .gray,
                                           regions: [])
        XCTAssertEqual(XPACommandMapper.get(command: "version", document: nil),
                       "Theia \(AppVersion.string)")
        XCTAssertEqual(XPACommandMapper.get(command: "frame", document: snapshot), "5")
        XCTAssertEqual(XPACommandMapper.get(command: "file", document: snapshot), "/data/star.fits")
        XCTAssertEqual(XPACommandMapper.get(command: "scale", document: snapshot), "pow")
        XCTAssertEqual(XPACommandMapper.get(command: "cmap", document: snapshot), "gray")
        XCTAssertEqual(XPACommandMapper.get(command: "regions", document: snapshot), "")
        XCTAssertNil(XPACommandMapper.get(command: "zoom", document: snapshot))
        XCTAssertEqual(XPACommandMapper.get(command: "frame", document: nil), "0")
    }

    func testScaleSetMapsPresetsAndRejectsUnsupportedModes() {
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "mode minmax", data: nil),
                       .session(.applyScalePreset(.minMax)))
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "mode 99.5", data: nil),
                       .session(.applyScalePreset(.percentile(lower: 0.25, upper: 99.75))))
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "histequal", data: nil),
                       .session(.setStretch(.histogramEq)))
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "limits 1 20", data: nil),
                       .session(.setLevels(min: 1, max: 20)))
        XCTAssertNil(XPACommandMapper.set(command: "scale", params: "mode bogus", data: nil))
        XCTAssertNil(XPACommandMapper.set(command: "scale", params: "mode nan", data: nil))
        XCTAssertNil(XPACommandMapper.set(command: "scale", params: "limits 1", data: nil))
        XCTAssertNil(XPACommandMapper.set(command: "scale", params: "limits 1e40 20", data: nil))
    }

    func testFileRegionsColormapAndQuitMapWithoutPlatformCode() {
        XCTAssertEqual(XPACommandMapper.set(command: "file", params: "", data: Data("/tmp/a.fits".utf8)),
                       .openFile("/tmp/a.fits"))
        XCTAssertEqual(XPACommandMapper.set(command: "cmap", params: "grey", data: nil),
                       .session(.setColormap(.gray)))
        XCTAssertEqual(XPACommandMapper.set(command: "regions", params: "", data: Data("image\n".utf8)),
                       .session(.replaceRegions([])))
        XCTAssertEqual(XPACommandMapper.set(command: "quit", params: "", data: nil), .quit)
        XCTAssertNil(XPACommandMapper.set(command: "file", params: "", data: nil))
        XCTAssertNil(XPACommandMapper.set(command: "cmap", params: "doesnotexist", data: nil))
        XCTAssertNil(XPACommandMapper.set(command: "zoom", params: "2", data: nil))
    }
}
