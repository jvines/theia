import Foundation
import XCTest
import FITSCore
import TheiaKit
@testable import FITSViewerApp

@MainActor
final class SessionAutosaveWatcherTests: XCTestCase {
    func testPersistedEventsDebounceAndCaptureLevelsAndStretchParameter() async throws {
        let session = try makeSession()
        var saved: [SessionState] = []
        let watcher = SessionAutosaveWatcher(session: session, debounceNanoseconds: 20_000_000) {
            saved.append($0)
        }
        watcher.start()
        defer { watcher.close() }
        _ = session.perform(.setLevels(min: 4, max: 18), origin: .user)
        _ = session.perform(.setStretchParameter(2.5), origin: .user)
        _ = session.perform(.setStretch(.asinh), origin: .user)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.vmin, 4)
        XCTAssertEqual(saved.first?.vmax, 18)
        XCTAssertEqual(saved.first?.stretchParameter, 2.5)
        XCTAssertEqual(saved.first?.stretch, .asinh)
    }

    func testPlaybackEventsDoNotSaveOrReplaceUserSelection() async throws {
        let session = try makeSession(cube: true)
        var saved: [SessionState] = []
        let watcher = SessionAutosaveWatcher(session: session, debounceNanoseconds: 20_000_000) {
            saved.append($0)
        }
        watcher.start()
        defer { watcher.close() }
        _ = session.perform(.selectPlane(1), origin: .user)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(saved.last?.selectedPlane, 1)
        let count = saved.count
        _ = session.perform(.setPlaying(true), origin: .user)
        session.tick(now: Date().addingTimeInterval(1))
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(saved.count, count)
        _ = session.perform(.setColorBarVisible(true), origin: .user)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(saved.last?.selectedPlane, 1)
    }

    func testSaveFailureReportsOncePerCause() async throws {
        struct Failure: LocalizedError { let code: Int; var errorDescription: String? { "save \(code)" } }
        let session = try makeSession()
        var cause = 1
        let watcher = SessionAutosaveWatcher(session: session, debounceNanoseconds: 20_000_000) { _ in
            throw Failure(code: cause)
        }
        watcher.start()
        defer { watcher.close() }
        _ = session.perform(.setGridVisible(true), origin: .user)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(watcher.failureNoticeID, 1)
        _ = session.perform(.setCompassVisible(true), origin: .user)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(watcher.failureNoticeID, 1)
        cause = 2
        _ = session.perform(.setColorBarVisible(true), origin: .user)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(watcher.failureNoticeID, 2)
    }

    func testCloseFlushesAnEditStillInsideTheDebounceWindow() throws {
        let session = try makeSession()
        var saved: [SessionState] = []
        let watcher = SessionAutosaveWatcher(session: session, debounceNanoseconds: 10_000_000_000) {
            saved.append($0)
        }
        watcher.start()
        _ = session.perform(.setLevels(min: 12, max: 34), origin: .user)
        XCTAssertTrue(saved.isEmpty)
        watcher.close()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.vmin, 12)
        XCTAssertEqual(saved.first?.vmax, 34)
    }

    func testStartingAfterStaleDecisionUsesCurrentSelection() async throws {
        let session = try makeSession(cube: true)
        var saved: [SessionState] = []
        let watcher = SessionAutosaveWatcher(session: session, debounceNanoseconds: 20_000_000) {
            saved.append($0)
        }
        _ = session.perform(.selectPlane(1), origin: .user)
        watcher.start()
        watcher.schedule()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(saved.last?.selectedPlane, 1)
        watcher.close()
    }

    private func makeSession(cube: Bool = false) throws -> DocumentSession {
        let axis = cube ? "NAXIS   =                    3" : "NAXIS   =                    2"
        let cards = ["SIMPLE  =                    T", "BITPIX  =                    8", axis,
                     "NAXIS1  =                    1", "NAXIS2  =                    1"] +
                    (cube ? ["NAXIS3  =                    2"] : []) + ["END"]
        let text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let header = Data(text.padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
        let pixels = cube ? Data([3, 4]) : Data([3])
        let data = header + pixels + Data(repeating: 0, count: 2880 - pixels.count)
        let file = try FITSFile(data: data)
        return DocumentSession(url: URL(fileURLWithPath: "/tmp/autosave.fits"), file: file)
    }
}
