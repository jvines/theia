import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class PhotometryTableTests: XCTestCase {
    func testImageRevisionAndWCSChangeRecomputeResults() async throws {
        let table = await MainActor.run { PhotometryTable() }
        let imageOne = FITSImage.fromFloat32(pixels: [Float](repeating: 1, count: 400),
                                              width: 20, height: 20)
        let imageTwo = FITSImage.fromFloat32(pixels: [Float](repeating: 2, count: 400),
                                              width: 20, height: 20)
        let region = Region(shape: .circle(center: .init(x: 180, y: 0),
                                           radius: .init(value: 5, unit: .arcsecond)),
                            frame: .icrs)
        let centered = try makeWCS(ra: 180)
        let shifted = try makeWCS(ra: 181)

        await MainActor.run {
            table.refresh(regions: [region], image: imageOne, imageRevision: 1, wcs: centered)
        }
        await table.idle()
        let firstSum = await MainActor.run { table.results[0]?.sum }
        XCTAssertGreaterThan(try XCTUnwrap(firstSum), 0)

        await MainActor.run {
            table.refresh(regions: [region], image: imageTwo, imageRevision: 2, wcs: centered)
        }
        await table.idle()
        let secondSum = await MainActor.run { table.results[0]?.sum }
        XCTAssertEqual(try XCTUnwrap(secondSum), try XCTUnwrap(firstSum) * 2, accuracy: 1e-6)

        await MainActor.run {
            table.refresh(regions: [region], image: imageTwo, imageRevision: 2, wcs: shifted)
        }
        await table.idle()
        let shiftedSum = await MainActor.run { table.results[0]?.sum }
        XCTAssertEqual(try XCTUnwrap(shiftedSum), 0)
    }

    func testGroupsSortTagsWithUntaggedLastAndSumResults() async throws {
        let table = await MainActor.run { PhotometryTable() }
        let image = FITSImage.fromFloat32(pixels: [Float](repeating: 1, count: 400),
                                           width: 20, height: 20)
        func circle(tag: String?) -> Region {
            Region(shape: .circle(center: .init(x: 11, y: 11),
                                  radius: .init(value: 2, unit: .pixel)),
                   frame: .image, attributes: tag.map { ["tag": $0] } ?? [:])
        }
        await MainActor.run {
            table.refresh(regions: [circle(tag: "B"), circle(tag: nil), circle(tag: "A")],
                          image: image, imageRevision: 1, wcs: nil)
        }
        await table.idle()
        let groups = await MainActor.run { table.groups }
        XCTAssertEqual(groups.map(\.tag), ["A", "B", ""])
        XCTAssertEqual(groups.map(\.rows.count), [1, 1, 1])
        XCTAssertTrue(groups.allSatisfy { $0.totalSum > 0 && $0.totalNetFlux == nil })
    }

    private func makeWCS(ra: Double) throws -> WCS {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'", "CTYPE2  = 'DEC--TAN'",
            "CRPIX1  =                 11.0", "CRPIX2  =                 11.0",
            "CRVAL1  = \(String(format: "%20.10f", ra))", "CRVAL2  =                  0.0",
            "CDELT1  =        -0.0002777778", "CDELT2  =         0.0002777778", "END",
        ]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        return try XCTUnwrap(WCS(header: FITSFile(data: Data(text.utf8)).hdus[0].header))
    }
}
