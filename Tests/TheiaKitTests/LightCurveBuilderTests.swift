import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class LightCurveBuilderTests: XCTestCase {
    func testImageApertureProjectsCenterAndPixelRadiusThroughTargetWCS() throws {
        let first = try frame(value: 2, crpix: 11, arcsecondsPerPixel: 1, mjd: 60002)
        let secondFile = try frame(value: 3, crpix: 11, arcsecondsPerPixel: 2, mjd: 60001)
        let displayedWCS = try frame(value: 0, crpix: 15, arcsecondsPerPixel: 2, mjd: nil).wcs
        let second = LightCurveFrame(image: secondFile.image, wcs: displayedWCS,
                                     header: secondFile.header)
        let aperture = Region(shape: .circle(center: .init(x: 11, y: 11),
                                             radius: .init(value: 4, unit: .pixel)),
                              frame: .image)

        let curve = try XCTUnwrap(LightCurveBuilder.build(region: aperture,
                                                          referenceWCS: first.wcs,
                                                          frames: [first, second]))

        XCTAssertEqual(curve.timeLabel, "MJD")
        XCTAssertEqual(curve.points.map(\.time), [60001, 60002])
        XCTAssertEqual(curve.points.map(\.flux), [39, 98])
        XCTAssertEqual(curve.points[0].err, sqrt(39), accuracy: 1e-9)
    }

    func testSkyApertureRetainsAngularRadiusForEachImageScale() throws {
        let first = try frame(value: 1, crpix: 11, arcsecondsPerPixel: 1, mjd: 60000)
        let second = try frame(value: 1, crpix: 15, arcsecondsPerPixel: 2, mjd: 60001)
        let aperture = Region(shape: .circle(center: .init(x: 180, y: 0),
                                             radius: .init(value: 4.5, unit: .arcsecond)),
                              frame: .icrs)

        let curve = try XCTUnwrap(LightCurveBuilder.build(region: aperture,
                                                          referenceWCS: first.wcs,
                                                          frames: [first, second]))

        XCTAssertEqual(curve.points.map(\.flux), [69, 21])
    }

    func testMissingTimeUsesFileIndexForAllSamples() throws {
        let first = try frame(value: 1, crpix: 11, arcsecondsPerPixel: 1, mjd: 60000)
        let second = try frame(value: 2, crpix: 11, arcsecondsPerPixel: 1, mjd: nil)
        let aperture = Region(shape: .circle(center: .init(x: 11, y: 11),
                                             radius: .init(value: 1, unit: .pixel)),
                              frame: .image)

        let curve = try XCTUnwrap(LightCurveBuilder.build(region: aperture,
                                                          referenceWCS: first.wcs,
                                                          frames: [first, second]))

        XCTAssertEqual(curve.timeLabel, "file index")
        XCTAssertEqual(curve.points.map(\.time), [0, 1])
        XCTAssertEqual(curve.points.map(\.flux), [5, 10])
    }

    private func frame(value: Float, crpix: Int, arcsecondsPerPixel: Int,
                       mjd: Int?) throws -> LightCurveFrame {
        var cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'", "CTYPE2  = 'DEC--TAN'",
            "CRPIX1  = \(String(format: "%20d", crpix))",
            "CRPIX2  = \(String(format: "%20d", crpix))",
            "CRVAL1  =                180.0", "CRVAL2  =                  0.0",
            "CDELT1  = \(String(format: "%20.12f", -Double(arcsecondsPerPixel) / 3600))",
            "CDELT2  = \(String(format: "%20.12f", Double(arcsecondsPerPixel) / 3600))",
        ]
        if let mjd { cards.append("MJD-OBS = \(String(format: "%20d", mjd))") }
        cards.append("END")
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        let header = try FITSFile(data: Data(text.utf8)).hdus[0].header
        let wcs = try XCTUnwrap(WCS(header: header))
        let image = FITSImage.fromFloat32(pixels: [Float](repeating: value, count: 31 * 31),
                                           width: 31, height: 31)
        return LightCurveFrame(image: image, wcs: wcs, header: header)
    }
}
