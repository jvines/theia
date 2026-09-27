import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class WorkspaceSyncTests: XCTestCase {
    func testTransformSyncAlignsImageCentresAcrossDifferentWindowSizes() async throws {
        try await MainActor.run {
            let first = try makeSession(name: "first")
            let second = try makeSession(name: "second")
            first.view.viewSizePoints = CGSize(width: 500, height: 300)
            second.view.viewSizePoints = CGSize(width: 1200, height: 800)
            let workspace = Workspace()
            workspace.register(first)
            workspace.register(second)
            _ = workspace.perform(.setSyncFlag(.zoomPan, true), origin: .user)

            var received: [SessionEvent] = []
            let observer = second.addEventObserver { event in
                if event.kind == .transformChanged { received.append(event) }
            }
            defer { second.removeEventObserver(observer) }

            let transform = ViewTransform(scale: 4, centre: SIMD2(12.5, 8.25))
            first.view.transform = transform
            XCTAssertEqual(second.view.transform, transform)
            XCTAssertEqual(received.count, 1)
            XCTAssertNotNil(received.first?.echoTag)
            XCTAssertEqual(received.first?.origin, .user)
        }
    }

    func testScaleAndColormapSyncCanBeEnabledSeparately() async throws {
        try await MainActor.run {
            let first = try makeSession(name: "first")
            let second = try makeSession(name: "second")
            let workspace = Workspace()
            workspace.register(first)
            workspace.register(second)
            _ = workspace.perform(.setSyncFlag(.scale, true), origin: .user)
            _ = workspace.perform(.setSyncFlag(.colormap, true), origin: .user)

            first.view.vmin = 7
            first.view.vmax = 17
            first.view.colorMap = .plasma
            XCTAssertEqual(second.view.vmin, 7)
            XCTAssertEqual(second.view.vmax, 17)
            XCTAssertEqual(second.view.colorMap, .plasma)

            _ = workspace.perform(.setSyncFlag(.scale, false), origin: .user)
            first.view.vmin = 3
            XCTAssertEqual(second.view.vmin, 7)
            first.view.colorMap = .viridis
            XCTAssertEqual(second.view.colorMap, .viridis)
        }
    }

    func testCursorSyncUsesDisplayedWCSAndClearsWhenDisabled() async throws {
        try await MainActor.run {
            let first = try makeSession(name: "first", crpix1: 1)
            let second = try makeSession(name: "second", crpix1: 2)
            let workspace = Workspace()
            workspace.register(first)
            workspace.register(second)
            _ = workspace.perform(.setSyncFlag(.crosshair, true), origin: .user)

            first.cursor = CursorInfo(imageX: 0, imageY: 0, value: 1)
            XCTAssertEqual(second.remoteCrosshair?.x ?? .nan, 1, accuracy: 1e-6)
            XCTAssertEqual(second.remoteCrosshair?.y ?? .nan, 0, accuracy: 1e-6)
            XCTAssertNil(first.remoteCrosshair)

            _ = workspace.perform(.setSyncFlag(.crosshair, false), origin: .user)
            XCTAssertNil(second.remoteCrosshair)
        }
    }

    func testCursorSyncUsesTheSelectedAlternateWCS() async throws {
        try await MainActor.run {
            let source = try makeSession(name: "source", alternateCrval1: 181)
            let target = try makeSession(name: "target", crval1: 181)
            let workspace = Workspace()
            workspace.register(source)
            workspace.register(target)
            _ = workspace.perform(.setSyncFlag(.crosshair, true), origin: .user)

            source.cursor = CursorInfo(imageX: 0, imageY: 0, value: 1)
            let primaryX = try XCTUnwrap(target.remoteCrosshair?.x)
            XCTAssertGreaterThan(abs(primaryX), 5)

            source.selectWCSVariant("A")
            source.cursor = nil
            source.cursor = CursorInfo(imageX: 0, imageY: 0, value: 1)
            XCTAssertEqual(target.remoteCrosshair?.x ?? .nan, 0, accuracy: 1e-4)
            XCTAssertEqual(target.remoteCrosshair?.y ?? .nan, 0, accuracy: 1e-4)
        }
    }

    func testCursorSyncConvertsBetweenCelestialFrames() async throws {
        try await MainActor.run {
            let icrs = try makeSession(name: "icrs")
            let galacticCenter = CelestialTransform.convert(lon: 180, lat: 0,
                                                            from: .icrs, to: .galactic)
            let galactic = try makeSession(name: "galactic", crpix1: 2,
                                           ctype1: "GLON-TAN", ctype2: "GLAT-TAN",
                                           crval1: galacticCenter.lon,
                                           crval2: galacticCenter.lat)
            let workspace = Workspace()
            workspace.register(icrs)
            workspace.register(galactic)
            _ = workspace.perform(.setSyncFlag(.crosshair, true), origin: .user)

            icrs.cursor = CursorInfo(imageX: 0, imageY: 0, value: 1)
            XCTAssertEqual(galactic.remoteCrosshair?.x ?? .nan, 1, accuracy: 1e-4)
            XCTAssertEqual(galactic.remoteCrosshair?.y ?? .nan, 0, accuracy: 1e-4)
        }
    }

    func testCursorSyncClearsTargetWhenSkyPointCannotBeProjected() async throws {
        try await MainActor.run {
            let source = try makeSession(name: "source")
            let oppositeSky = try makeSession(name: "opposite-sky", crval1: 0)
            let workspace = Workspace()
            workspace.register(source)
            workspace.register(oppositeSky)
            _ = workspace.perform(.setSyncFlag(.crosshair, true), origin: .user)

            source.cursor = CursorInfo(imageX: 0, imageY: 0, value: 1)
            XCTAssertNil(oppositeSky.remoteCrosshair)
        }
    }

    func testUnregisterStopsSyncingClosedDocument() async throws {
        try await MainActor.run {
            let first = try makeSession(name: "first")
            let second = try makeSession(name: "second")
            let workspace = Workspace()
            workspace.register(first)
            workspace.register(second)
            _ = workspace.perform(.setSyncFlag(.zoomPan, true), origin: .user)
            workspace.unregister(second)

            first.view.transform = ViewTransform(scale: 3, centre: SIMD2(1, 1))
            XCTAssertNotEqual(second.view.transform, first.view.transform)
        }
    }

    func testDocumentIDsAreMonotonicAndFocusFollowsOpenAndClose() async throws {
        try await MainActor.run {
            let first = try makeSession(name: "first")
            let second = try makeSession(name: "second")
            let third = try makeSession(name: "third")
            let workspace = Workspace()

            workspace.register(first)
            XCTAssertEqual(workspace.id(of: first), 0)
            XCTAssertEqual(workspace.focusedDocumentID, 0)
            workspace.register(second)
            XCTAssertEqual(workspace.id(of: second), 1)
            XCTAssertEqual(workspace.focusedDocumentID, 1)
            workspace.focus(first)
            XCTAssertEqual(workspace.focusedDocumentID, 0)
            XCTAssertTrue(workspace.document(at: 1) === second)

            workspace.unregister(first)
            XCTAssertEqual(workspace.focusedDocumentID, 1)
            workspace.unregister(second)
            XCTAssertNil(workspace.focusedDocumentID)
            workspace.register(third)
            XCTAssertEqual(workspace.id(of: third), 2)
            XCTAssertEqual(workspace.focusedDocumentID, 2)
            XCTAssertNil(workspace.document(at: 0))
        }
    }

    func testOpenRegistersOnceAndReturnsWindowAndRecentEffects() async throws {
        try await MainActor.run {
            let workspace = Workspace()
            var loads = 0
            let path = "/tmp/workspace-first.fits"
            let first = try workspace.open(path: path) { _ in
                loads += 1
                return try makeSession(name: "first")
            }
            XCTAssertEqual(first.documentID, 0)
            XCTAssertFalse(first.wasAlreadyOpen)
            XCTAssertEqual(first.effects, [.documentOpened(0),
                                           .noteRecent(URL(fileURLWithPath: path))])

            let again = try workspace.open(path: path) { _ in
                loads += 1
                return try makeSession(name: "unexpected")
            }
            XCTAssertEqual(loads, 1)
            XCTAssertEqual(again.documentID, 0)
            XCTAssertTrue(again.wasAlreadyOpen)
            XCTAssertEqual(again.effects, [.documentOpened(0)])
            XCTAssertTrue(again.session === first.session)
        }
    }

    func testFailedOpenDoesNotReserveAnIDOrFocus() async throws {
        enum LoadFailure: Error { case unreadable }
        try await MainActor.run {
            let workspace = Workspace()
            XCTAssertThrowsError(try workspace.open(path: "/tmp/missing.fits") { _ in
                throw LoadFailure.unreadable
            })
            XCTAssertNil(workspace.focusedDocumentID)

            let opened = try workspace.open(path: "/tmp/workspace-first.fits") { _ in
                try makeSession(name: "first")
            }
            XCTAssertEqual(opened.documentID, 0)
        }
    }

    @MainActor private func makeSession(name: String, crpix1: Int = 1,
                                        ctype1: String = "RA---TAN", ctype2: String = "DEC--TAN",
                                        crval1: Double = 180, crval2: Double = 0,
                                        alternateCrval1: Double? = nil) throws -> DocumentSession {
        var cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8",
            "NAXIS   =                    2", "NAXIS1  =                    2",
            "NAXIS2  =                    2", "CTYPE1  = '\(ctype1)'",
            "CTYPE2  = '\(ctype2)'", "CRPIX1  =                   \(crpix1)",
            "CRPIX2  =                    1", "CRVAL1  = \(crval1)",
            "CRVAL2  = \(crval2)", "CDELT1  =                 -0.1",
            "CDELT2  =                  0.1", "END",
        ]
        if let alternateCrval1 {
            cards.insert(contentsOf: [
                "CTYPE1A = 'RA---TAN'", "CTYPE2A = 'DEC--TAN'",
                "CRPIX1A =                    1", "CRPIX2A =                    1",
                "CRVAL1A = \(alternateCrval1)", "CRVAL2A =                  0.0",
                "CDELT1A =                 -0.1", "CDELT2A =                  0.1",
            ], at: cards.count - 1)
        }
        let header = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let data = Data(header.padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            + Data([1, 2, 3, 4]) + Data(repeating: 0, count: 2876)
        return DocumentSession(url: URL(fileURLWithPath: "/tmp/workspace-\(name).fits"),
                               file: try FITSFile(data: data))
    }
}
