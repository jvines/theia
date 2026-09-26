import Foundation
import XCTest
import Observation
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

    func testRegionsSelectionPreviewAndRemoteCrosshairBelongToSession() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let region = Region(shape: .point(.init(x: 1, y: 2)), frame: .image)
            session.regions = [region]
            session.selectedRegionIndex = 0
            session.previewRegion = region
            session.remoteCrosshair = SIMD2(3, 4)

            XCTAssertEqual(session.regions, [region])
            XCTAssertEqual(session.selectedRegionIndex, 0)
            XCTAssertEqual(session.previewRegion, region)
            XCTAssertEqual(session.remoteCrosshair, SIMD2(3, 4))

            session.selectedRegionIndex = 99
            XCTAssertNil(session.selectedRegionIndex)
            session.selectedRegionIndex = 0

            var regionChangeObserved = false
            withObservationTracking {
                _ = session.regions
            } onChange: {
                regionChangeObserved = true
            }
            session.regions = []
            XCTAssertTrue(regionChangeObserved)
            XCTAssertNil(session.selectedRegionIndex)
            XCTAssertNil(session.previewRegion)
        }
    }

    func testDocumentTextPreservesHDUAndStatusReadouts() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let cube = session.file.hdus[1]
            XCTAssertEqual(DocumentText.windowSubtitle(for: session.file), "6 HDUs · 2 × 2 × 2 · uint8")
            XCTAssertEqual(DocumentText.hduLabel(index: 1, name: nil), "HDU 1")
            XCTAssertEqual(DocumentText.hduLabel(index: 2, name: "SCI"), "HDU 2 — SCI")
            XCTAssertEqual(DocumentText.sidebarDetails(for: cube), "3D cube · 2 × 2 × 2 · uint8")
            XCTAssertEqual(DocumentText.statusDetails(for: cube), "2 × 2 × 2 · uint8")
            XCTAssertEqual(DocumentText.pixelCoordinates(imageX: 0, imageY: 4), "(1, 5)")
            XCTAssertEqual(DocumentText.pixelValue(.nan), "NaN")
            XCTAssertEqual(DocumentText.pixelValue(1.23456), "1.235")
            XCTAssertEqual(DocumentText.level(0), "0.00e+00")
            XCTAssertEqual(DocumentText.level(1000), "1.00e+03")
        }
    }

    func testRestoredDisplayAndRegionsAreReadyBeforeViewAppears() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let region = Region(shape: .point(.init(x: 2, y: 3)), frame: .image)
            let saved = SessionState(
                selectedHDU: 2, selectedPlane: 0, stretch: .log, colorMap: .plasma,
                drawMode: "pan", vmin: 12, vmax: 45, stretchParameter: 3,
                showWCSGrid: true, showCompass: false, showColorBar: false,
                regions: [region],
                contour: .init(enabled: true, count: 1, minValue: 12, maxValue: 16, spacing: "linear")
            )
            session.restoreInitialState(saved)
            XCTAssertEqual(session.hdu, 2)
            XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 11)
            XCTAssertEqual(session.view.vmin, 12)
            XCTAssertEqual(session.view.vmax, 45)
            XCTAssertEqual(session.view.stretch, .log)
            XCTAssertEqual(session.view.colorMap, .plasma)
            XCTAssertEqual(session.view.stretchParameter, 3)
            XCTAssertEqual(session.regions, [region])
            XCTAssertTrue(session.showGrid)
            XCTAssertEqual(session.contourSegments.count, 1)

            session.regions = [] // an immediate script edit wins over the saved value
            XCTAssertTrue(session.regions.isEmpty)
        }
    }

    func testZScaleResetsDisplayedLevelsWithoutToolbarCallbacks() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let image = try XCTUnwrap(session.displayed)
            let expected = DocumentSession.recommendedLevels(for: image)
            session.view.vmin = -100
            session.view.vmax = 100
            session.resetLevels()
            XCTAssertEqual(session.view.vmin, expected.vmin)
            XCTAssertEqual(session.view.vmax, expected.vmax)
        }
    }

    func testScalePresetsReadTheDisplayedImage() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let derived = FITSImage.fromFloat32(pixels: [10, 20, 30, 40], width: 2, height: 2)
            session.setDerived(DerivedImage(image: derived, wcs: nil, label: "scaled"))
            session.setMinMaxLevels()
            XCTAssertEqual(session.view.vmin, 10)
            XCTAssertEqual(session.view.vmax, 40)
            session.view.vmin = -1
            session.view.vmax = -1
            session.setPercentileLevels(lower: 0, upper: 100)
            XCTAssertEqual(session.view.vmin, 10)
            XCTAssertEqual(session.view.vmax, 40)
        }
    }

    func testOverlayStateAndContoursFollowTheDisplayedPlane() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.showGrid = true
            session.showCompass = true
            session.showColorBar = true
            var contourChangeObserved = false
            withObservationTracking {
                _ = session.contourSegments
            } onChange: {
                contourChangeObserved = true
            }
            session.setContourSpec(ContourSpec(
                enabled: true, count: 1, minValue: 1, maxValue: 2, spacing: .linear
            ))
            XCTAssertTrue(contourChangeObserved)
            XCTAssertTrue(session.showGrid)
            XCTAssertTrue(session.showCompass)
            XCTAssertTrue(session.showColorBar)
            XCTAssertEqual(session.contourSegments.count, 1)
            XCTAssertFalse(session.contourSegments[0].segments.isEmpty)

            session.selectPlane(1)
            XCTAssertTrue(session.contourSegments[0].segments.isEmpty)
            session.selectPlane(0)
            XCTAssertFalse(session.contourSegments[0].segments.isEmpty)
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
