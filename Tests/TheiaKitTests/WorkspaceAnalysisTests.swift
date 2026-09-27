import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class WorkspaceAnalysisTests: XCTestCase {
    func testStackUsesOtherDocumentsDisplayedImage() async throws {
        let (workspace, reference, other) = try await MainActor.run {
            let workspace = Workspace()
            let reference = try makeSession(name: "reference", value: 1)
            let other = try makeSession(name: "other", value: 2)
            let replacement = FITSImage.fromFloat32(
                pixels: [Float](repeating: 10, count: 31 * 31), width: 31, height: 31)
            other.setDerived(DerivedImage(image: replacement, wcs: other.displayedWCS,
                                          label: "Filtered"))
            workspace.register(reference)
            workspace.register(other)
            XCTAssertNil(workspace.perform(.stack(documentID: 0, mode: .sum),
                                           origin: .user).failure)
            return (workspace, reference, other)
        }

        await reference.idle()
        await MainActor.run {
            XCTAssertEqual(reference.displayed?.physicalValue(x: 10, y: 10), 11)
            XCTAssertEqual(reference.derived?.label, "Stack Sum of 2 windows")
            XCTAssertEqual(reference.displayedWCS?.crval.ra, 180)
            XCTAssertTrue(workspace.document(at: 1) === other)
        }
    }

    func testLightCurveUsesDisplayedImagesInWorkspaceOrder() async throws {
        try await MainActor.run {
            let workspace = Workspace()
            let reference = try makeSession(name: "reference", value: 1)
            let other = try makeSession(name: "other", value: 2)
            let replacement = FITSImage.fromFloat32(
                pixels: [Float](repeating: 3, count: 31 * 31), width: 31, height: 31)
            other.setDerived(DerivedImage(image: replacement, wcs: other.displayedWCS,
                                          label: "Filtered"))
            reference.regions = [Region(shape: .circle(center: .init(x: 11, y: 11),
                                                       radius: .init(value: 1, unit: .pixel)),
                                        frame: .image)]
            reference.selectedRegionIndex = 0
            workspace.register(reference)
            workspace.register(other)

            let outcome = workspace.perform(.lightCurve(documentID: 0), origin: .user)
            XCTAssertNil(outcome.failure)
            guard case .openLightCurve(let curve)? = outcome.effects.first else {
                return XCTFail("Expected a light curve effect")
            }
            XCTAssertEqual(curve.timeLabel, "file index")
            XCTAssertEqual(curve.points.map(\.time), [0, 1])
            XCTAssertEqual(curve.points.map(\.flux), [5, 15])
        }
    }

    func testLightCurveReportsSpecificMissingInputs() async throws {
        try await MainActor.run {
            let workspace = Workspace()
            let reference = try makeSession(name: "reference", value: 1)
            workspace.register(reference)

            XCTAssertEqual(workspace.perform(.lightCurve(documentID: 0), origin: .user).failure,
                           .noSelectedRegion)
            reference.regions = [Region(shape: .circle(center: .init(x: 11, y: 11),
                                                       radius: .init(value: 1, unit: .pixel)),
                                        frame: .image)]
            reference.selectedRegionIndex = 0
            XCTAssertEqual(workspace.perform(.stack(documentID: 0, mode: .sum),
                                             origin: .user).failure,
                           .insufficientStackImages)
            reference.setDerived(DerivedImage(image: reference.displayed!, wcs: nil,
                                              label: "Uncalibrated"))
            XCTAssertEqual(workspace.perform(.lightCurve(documentID: 0), origin: .user).failure,
                           .noDisplayedWCS)
            reference.setDerived(nil)
            XCTAssertEqual(workspace.perform(.lightCurve(documentID: 0), origin: .user).failure,
                           .insufficientLightCurveFrames)
            XCTAssertEqual(workspace.perform(.lightCurve(documentID: 42), origin: .user).failure,
                           .documentClosed)
        }
    }

    @MainActor private func makeSession(name: String, value: UInt8) throws -> DocumentSession {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8",
            "NAXIS   =                    2", "NAXIS1  =                   31",
            "NAXIS2  =                   31", "CTYPE1  = 'RA---TAN'",
            "CTYPE2  = 'DEC--TAN'", "CRPIX1  =                   11",
            "CRPIX2  =                   11", "CRVAL1  =                180.0",
            "CRVAL2  =                  0.0", "CDELT1  =      -0.000277777778",
            "CDELT2  =       0.000277777778", "END",
        ]
        let header = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let data = Data(header.padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            + Data(repeating: value, count: 31 * 31)
            + Data(repeating: 0, count: 2880 - 31 * 31)
        return DocumentSession(url: URL(fileURLWithPath: "/tmp/workspace-\(name).fits"),
                               file: try FITSFile(data: data))
    }
}
