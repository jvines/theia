import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKSessionPersistenceTests: XCTestCase {
    @MainActor func testAutosaveRestoresAndChangedFileRequiresExplicitChoice() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("source.fits")
        let data = try Data(contentsOf: fixture)
        try data.write(to: fileURL)
        let paths = AppPaths(platform: .linux, homeDirectory: root,
                             environment: ["XDG_STATE_HOME": root.path])
        let first = DocumentSession(url: fileURL, file: try FITSFile(data: data))
        let autosave = GTKSessionPersistence(session: first, fileData: data, paths: paths,
                                             debounceNanoseconds: 1_000_000)
        XCTAssertNotNil(autosave.identity, autosave.warningMessage ?? "")
        autosave.start()
        _ = first.perform(.setLevels(min: 10, max: 40), origin: .user)
        XCTAssertEqual(first.view.vmin, 10)
        autosave.close()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try autosave.store.recordURL(for: fileURL).path
        ), autosave.warningMessage ?? "session record missing")

        let second = DocumentSession(url: fileURL, file: try FITSFile(data: data))
        let restored = GTKSessionPersistence(session: second, fileData: data, paths: paths)
        XCTAssertNil(restored.staleState)
        XCTAssertEqual(second.view.vmin, 10)
        XCTAssertEqual(second.view.vmax, 40)

        var changed = data
        let note = "COMMENT GTK stale restore check".padding(
            toLength: 80, withPad: " ", startingAt: 0
        )
        changed.replaceSubrange(800..<880, with: note.utf8)
        try changed.write(to: fileURL)
        let third = DocumentSession(url: fileURL, file: try FITSFile(data: changed))
        let stale = GTKSessionPersistence(session: third, fileData: changed, paths: paths)
        XCTAssertNotNil(stale.staleState)
        XCTAssertNotEqual(third.view.vmin, 10)
        stale.restoreStale()
        XCTAssertEqual(third.view.vmin, 10)
        XCTAssertEqual(third.view.vmax, 40)
        stale.close()
    }
}
