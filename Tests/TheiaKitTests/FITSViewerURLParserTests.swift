import Foundation
import XCTest
@testable import TheiaKit

final class FITSViewerURLParserTests: XCTestCase {
    func testOpenURLDecodesPathAndOrdersScriptCommands() throws {
        let url = try XCTUnwrap(URL(string: "fitsviewer://open?path=%2Ftmp%2Fstar%20field.fits&stretch=asinh&colormap=plasma&vmin=5&vmax=50&zscale=1"))
        let request = try XCTUnwrap(FITSViewerURLParser.parse(url))

        XCTAssertEqual(request.fileURL.path, "/tmp/star field.fits")
        XCTAssertEqual(request.commands(currentVmin: 0, currentVmax: 1), [
            .setStretch(.asinh), .setColormap(.plasma),
            .setLevels(min: 5, max: 1), .setLevels(min: 5, max: 50),
            .applyScalePreset(.zscale),
        ])
    }

    func testInvalidOpenURLsAreRejectedWithoutGuessingPaths() throws {
        XCTAssertNil(FITSViewerURLParser.parse(try XCTUnwrap(URL(string: "fitsviewer://open"))))
        XCTAssertNil(FITSViewerURLParser.parse(try XCTUnwrap(URL(string: "fitsviewer://open?path=relative.fits"))))
        XCTAssertNil(FITSViewerURLParser.parse(try XCTUnwrap(URL(string: "fitsviewer://other?path=%2Ftmp%2Fa.fits"))))
    }

    func testUnknownSettingsAreIgnoredAndFirstValueWins() throws {
        let url = try XCTUnwrap(URL(string: "fitsviewer://open?path=%2Ftmp%2Fa.fits&stretch=bogus&vmin=3&vmin=8&zscale=0"))
        let request = try XCTUnwrap(FITSViewerURLParser.parse(url))
        XCTAssertEqual(request.commands(currentVmin: 0, currentVmax: 10), [
            .setLevels(min: 3, max: 10),
        ])
    }

    func testOpenURLPreservesSSHLocationForRemoteAppOpen() throws {
        let url = try XCTUnwrap(URL(string:
            "fitsviewer://open?path=ssh%3A%2F%2Fjose%40cluster.example%2Fdata%2Fimage%2520one.fits&stretch=log"
        ))
        let request = try XCTUnwrap(FITSViewerURLParser.parse(url))
        XCTAssertEqual(request.fileURL.absoluteString,
                       "ssh://jose@cluster.example/data/image%20one.fits")
        XCTAssertEqual(request.commands(currentVmin: 0, currentVmax: 1), [.setStretch(.log)])
        XCTAssertNil(FITSViewerURLParser.parse(try XCTUnwrap(URL(string:
            "fitsviewer://open?path=ssh%3A%2F%2Fcluster.example"
        ))))
    }
}
