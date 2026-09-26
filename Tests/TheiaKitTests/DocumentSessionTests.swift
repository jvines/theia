import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class DocumentSessionTests: XCTestCase {
    func testDisplayedCachesPlanesAndTracksPixelRevisions() async throws {
        try await MainActor.run {
        let session = try makeSession()
        XCTAssertEqual(session.hdu, 1)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(session.view.image?.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(session.view.imageRevision, session.imageRevision)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(session.decodedImageCount, 1)

        let firstRevision = session.imageRevision
        session.selectPlane(1)
        XCTAssertEqual(session.imageRevision, firstRevision + 1)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 4)
        XCTAssertEqual(session.view.image?.physicalValue(x: 0, y: 0), 4)
        XCTAssertEqual(session.view.imageRevision, session.imageRevision)
        session.selectPlane(0)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(session.decodedImageCount, 2)

        session.selectHDU(4)
        XCTAssertNil(session.displayed) // table HDU
        session.selectHDU(0)
        XCTAssertNil(session.displayed) // data-less primary
        }
    }

    func testDerivedImageAndWCSFollowTheDisplayedPixels() async throws {
        try await MainActor.run {
        let session = try makeSession()
        XCTAssertEqual(session.displayedWCS?.crval.ra, 10)
        session.selectWCSVariant("A")
        XCTAssertEqual(session.displayedWCS?.crval.ra, 20)
        XCTAssertEqual(session.availableWCSVariants, ["", "A"])

        let derived = FITSImage.fromFloat32(pixels: [99, 99, 99, 99], width: 2, height: 2)
        let revision = session.imageRevision
        session.setDerived(DerivedImage(image: derived, wcs: nil, label: "Filtered"))
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 99)
        XCTAssertNil(session.displayedWCS)
        XCTAssertEqual(session.availableWCSVariants, [])
        session.selectWCSVariant("")
        XCTAssertEqual(session.wcsVariant, "A")
        XCTAssertEqual(session.imageRevision, revision + 1)

        session.setDerived(DerivedImage(image: derived, wcs: session.facts[1].wcs(variant: "A"), label: "Same geometry"))
        XCTAssertEqual(session.availableWCSVariants, ["A"])

        session.selectHDU(2)
        XCTAssertNil(session.derived)
        XCTAssertEqual(session.plane, 0)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 11)
        }
    }

    func testBlinkPartnerSkipsDifferentShapesAndNonImages() async throws {
        try await MainActor.run {
        let session = try makeSession()
        XCTAssertEqual(session.blinkPartner, 2)
        session.selectHDU(3)
        XCTAssertNil(session.blinkPartner)
        }
    }

    func testFourDimensionalCubeExposesEveryFlattenedPlane() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.selectHDU(5)
            XCTAssertEqual(session.facts[5].planeCount, 4)
            session.selectPlane(3)
            XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 12)
        }
    }

    @MainActor
    private func makeSession() throws -> DocumentSession {
        var data = Data()
        appendHDU(&data, cards: ["SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0"], pixels: [])
        appendHDU(&data, cards: imageCards(width: 2, height: 2, depth: 2) + wcsCards(suffix: "", ra: 10) + wcsCards(suffix: "A", ra: 20), pixels: Array(0..<8).map(UInt8.init))
        appendHDU(&data, cards: imageCards(width: 2, height: 2), pixels: [11, 12, 13, 14])
        appendHDU(&data, cards: imageCards(width: 3, height: 2), pixels: [1, 2, 3, 4, 5, 6])
        appendHDU(&data, cards: ["XTENSION= 'BINTABLE'", "BITPIX  =                    8", "NAXIS   =                    2", "NAXIS1  =                    0", "NAXIS2  =                    0", "PCOUNT  =                    0", "GCOUNT  =                    1", "TFIELDS =                    0"], pixels: [])
        appendHDU(&data, cards: imageCards(width: 2, height: 2, depth: 2, fourthAxis: 2), pixels: Array(0..<16).map(UInt8.init))
        return DocumentSession(url: URL(fileURLWithPath: "/tmp/session.fits"), file: try FITSFile(data: data))
    }

    private func imageCards(width: Int, height: Int, depth: Int? = nil, fourthAxis: Int? = nil) -> [String] {
        ["XTENSION= 'IMAGE   '", "BITPIX  =                    8", "NAXIS   = \(String(format: "%20d", fourthAxis != nil ? 4 : depth == nil ? 2 : 3))", "NAXIS1  = \(String(format: "%20d", width))", "NAXIS2  = \(String(format: "%20d", height))"]
        + (depth.map { ["NAXIS3  = \(String(format: "%20d", $0))"] } ?? [])
        + (fourthAxis.map { ["NAXIS4  = \(String(format: "%20d", $0))"] } ?? [])
        + ["PCOUNT  =                    0", "GCOUNT  =                    1"]
    }

    private func wcsCards(suffix: String, ra: Int) -> [String] {
        func card(_ key: String, _ value: String) -> String {
            "\(key.padding(toLength: 8, withPad: " ", startingAt: 0))= \(value)"
        }
        return [
            card("CTYPE1\(suffix)", "'RA---TAN'"), card("CTYPE2\(suffix)", "'DEC--TAN'"),
            card("CRPIX1\(suffix)", "1"), card("CRPIX2\(suffix)", "1"),
            card("CRVAL1\(suffix)", "\(ra)"), card("CRVAL2\(suffix)", "0"),
            card("CDELT1\(suffix)", "-0.1"), card("CDELT2\(suffix)", "0.1")
        ]
    }

    private func appendHDU(_ data: inout Data, cards: [String], pixels: [UInt8]) {
        var header = (cards + ["END"]).map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        header += String(repeating: " ", count: (2880 - header.utf8.count % 2880) % 2880)
        data.append(contentsOf: header.utf8)
        data.append(contentsOf: pixels)
        data.append(Data(repeating: 0, count: (2880 - pixels.count % 2880) % 2880))
    }
}
