import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class CubeSessionOperationTests: XCTestCase {
    func testCubeOperationsRejectPendingOrDisplayedTwoDimensionalEdits() async throws {
        let session = try await MainActor.run { try makeSession() }
        await MainActor.run {
            XCTAssertNil(session.perform(.unary(.square), origin: .user).failure)
            XCTAssertEqual(session.perform(.collapseCube(.sum), origin: .user).failure,
                           .requiresOriginalCube)
        }
        await session.idle()
        await MainActor.run {
            XCTAssertEqual(session.perform(.applySlab(from: 0, to: 2), origin: .user).failure,
                           .requiresOriginalCube)
            XCTAssertEqual(session.perform(.extractSlab, origin: .user).failure,
                           .requiresOriginalCube)
        }
    }

    func testCollapseUsesSourceCubeAndSelectedWCS() async throws {
        let session = try await MainActor.run { try makeSession() }
        await MainActor.run {
            XCTAssertNil(session.perform(.selectWCSVariant("A"), origin: .user).failure)
            XCTAssertNil(session.perform(.collapseCube(.sum), origin: .user).failure)
        }
        await session.idle()
        await MainActor.run {
            XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 10)
            XCTAssertEqual(session.derived?.label, "Sum over plane axis")
            XCTAssertEqual(session.displayedWCS?.crval.ra, 20)
        }
    }

    func testSlabUsesSourceCubeAndSelectedWCS() async throws {
        let session = try await MainActor.run { try makeSession() }
        await MainActor.run {
            XCTAssertNil(session.perform(.selectWCSVariant("A"), origin: .user).failure)
            XCTAssertNil(session.perform(.applySlab(from: 1, to: 2), origin: .user).failure)
        }
        await session.idle()
        await MainActor.run {
            XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 8)
            XCTAssertEqual(session.derived?.label, "Slab 1…2 (sum)")
            XCTAssertEqual(session.displayedWCS?.crval.ra, 20)
        }
    }

    func testCubeCommandsValidateSourceAndInclusiveBounds() async throws {
        try await MainActor.run {
            let session = try makeSession()
            for (from, to) in [(-1, 1), (0, 3), (2, 1)] {
                XCTAssertEqual(session.perform(.applySlab(from: from, to: to),
                                               origin: .user).failure,
                               .invalidSlabRange(from: from, to: to))
            }
            XCTAssertNil(session.perform(.selectHDU(1), origin: .user).failure)
            XCTAssertEqual(session.perform(.collapseCube(.sum), origin: .user).failure,
                           .unavailableCube)
            XCTAssertEqual(session.perform(.applySlab(from: 0, to: 0), origin: .user).failure,
                           .unavailableCube)
        }
    }

    func testPlaneChangeCancelsQueuedCollapse() async throws {
        let session = try await MainActor.run { try makeSession() }
        await MainActor.run {
            XCTAssertNil(session.perform(.collapseCube(.sum), origin: .user).failure)
            XCTAssertNil(session.perform(.selectPlane(1), origin: .user).failure)
        }
        await session.idle()
        await MainActor.run {
            XCTAssertNil(session.derived)
            XCTAssertEqual(session.plane, 1)
            XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 3)
        }
    }

    @MainActor private func makeSession() throws -> DocumentSession {
        var data = Data()
        appendHDU(&data, cards: [
            "SIMPLE  =                    T", "BITPIX  =                    8",
            "NAXIS   =                    3", "NAXIS1  =                    1",
            "NAXIS2  =                    1", "NAXIS3  =                    3",
            "CTYPE1  = 'RA---TAN'", "CTYPE2  = 'DEC--TAN'",
            "CRPIX1  =                    1", "CRPIX2  =                    1",
            "CRVAL1  =                   10", "CRVAL2  =                    0",
            "CDELT1  =                 -0.1", "CDELT2  =                  0.1",
            "CTYPE1A = 'RA---TAN'", "CTYPE2A = 'DEC--TAN'",
            "CRPIX1A =                    1", "CRPIX2A =                    1",
            "CRVAL1A =                   20", "CRVAL2A =                    0",
            "CDELT1A =                 -0.1", "CDELT2A =                  0.1",
        ], pixels: [2, 3, 5])
        appendHDU(&data, cards: [
            "XTENSION= 'IMAGE   '", "BITPIX  =                    8",
            "NAXIS   =                    2", "NAXIS1  =                    1",
            "NAXIS2  =                    1", "PCOUNT  =                    0",
            "GCOUNT  =                    1",
        ], pixels: [9])
        return DocumentSession(url: URL(fileURLWithPath: "/tmp/cube-session.fits"),
                               file: try FITSFile(data: data))
    }

    private func appendHDU(_ data: inout Data, cards: [String], pixels: [UInt8]) {
        var header = (cards + ["END"])
            .map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        header += String(repeating: " ", count: (2880 - header.utf8.count % 2880) % 2880)
        data.append(contentsOf: header.utf8)
        data.append(contentsOf: pixels)
        data.append(Data(repeating: 0, count: (2880 - pixels.count % 2880) % 2880))
    }
}
