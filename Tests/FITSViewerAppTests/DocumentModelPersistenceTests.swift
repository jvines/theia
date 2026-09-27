import Foundation
import XCTest
import FITSCore
import TheiaKit
@testable import FITSViewerApp

@MainActor
final class DocumentModelPersistenceTests: XCTestCase {
    func testOpenRestoresCurrentStoreRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.fits")
        let data = fits(date: "2026-09-27")
        try data.write(to: source)
        let paths = pathsForTests(root)
        let store = SessionStore(paths: paths)
        var state = savedState()
        state.vmin = 12
        try store.save(state, for: source, fileData: data)

        let model = try DocumentModel(url: source, paths: paths)
        XCTAssertEqual(model.restoredState, state)
        XCTAssertNil(model.staleState)
        XCTAssertEqual(model.session.view.vmin, 12)
    }

    func testOpenRetainsChangedFileSessionForRestoreAnyway() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("latest.fits")
        let oldData = fits(date: "2026-09-27")
        let newData = fits(date: "2026-09-28")
        try oldData.write(to: source)
        let paths = pathsForTests(root)
        let store = SessionStore(paths: paths)
        var oldState = savedState()
        oldState.vmin = 12
        try store.save(oldState, for: source, fileData: oldData)
        try newData.write(to: source)

        let model = try DocumentModel(url: source, paths: paths)
        XCTAssertNil(model.restoredState)
        XCTAssertEqual(model.staleState, oldState)
        XCTAssertNotEqual(model.session.view.vmin, 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.staleRecordURL(for: source).path))
    }

    func testOpenAppliesCurrentAndStillOffersUndismissedArchive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("latest.fits")
        let oldData = fits(date: "2026-09-27")
        let newData = fits(date: "2026-09-28")
        try oldData.write(to: source)
        let paths = pathsForTests(root)
        let store = SessionStore(paths: paths)
        var oldState = savedState()
        oldState.vmin = 12
        try store.save(oldState, for: source, fileData: oldData)
        try newData.write(to: source)
        _ = try store.load(for: source, fileData: newData)
        var current = savedState()
        current.vmin = 23
        try store.save(current, for: source, fileData: newData)

        let model = try DocumentModel(url: source, paths: paths)
        XCTAssertEqual(model.restoredState, current)
        XCTAssertEqual(model.staleState, oldState)
        XCTAssertEqual(model.session.view.vmin, 23)
    }

    private func pathsForTests(_ root: URL) -> AppPaths {
        AppPaths(platform: .linux, homeDirectory: root, environment: ["XDG_STATE_HOME": root.path])
    }

    private func savedState() -> SessionState {
        SessionState(selectedHDU: 0, selectedPlane: 0, stretch: .linear, colorMap: .gray,
                     drawMode: .pan, vmin: 0, vmax: 1, stretchParameter: 1,
                     showWCSGrid: false, showCompass: false, showColorBar: false, regions: [])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentModelPersistenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fits(date: String) -> Data {
        let cards = ["SIMPLE  =                    T", "BITPIX  =                    8",
                     "NAXIS   =                    2", "NAXIS1  =                    1", "NAXIS2  =                    1",
                     "DATE-OBS= '\(date)'", "END"]
        let text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let header = Data(text.padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
        return header + Data([3]) + Data(repeating: 0, count: 2879)
    }
}
