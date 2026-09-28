import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class SessionStoreTests: XCTestCase {
    func testDefaultContourNaNSurvivesSessionStoreAndSidecarJSON() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("contour.fits")
        let data = primary()
        try data.write(to: source)
        var state = session()
        state.contour = .init(enabled: false, count: 5, minValue: .nan,
                              maxValue: .nan, spacing: "linear")
        let persistence = store(root)
        try persistence.save(state, for: source, fileData: data)
        guard case .restored(let restored) = try persistence.load(for: source, fileData: data) else {
            return XCTFail("Expected saved session")
        }
        XCTAssertTrue(try XCTUnwrap(restored.contour).minValue.isNaN)
        XCTAssertTrue(try XCTUnwrap(restored.contour).maxValue.isNaN)
        let sidecar = try SessionState.fromJSON(state.toJSON())
        XCTAssertTrue(try XCTUnwrap(sidecar.contour).minValue.isNaN)
    }

    func testFNV1a64HasPinnedVector() {
        XCTAssertEqual(SessionStore.fnv1a64Hex(Data("hello".utf8)), "a430d84680aabd0b")
    }

    func testRecordNameUsesCanonicalPathAndIsStableAcrossStoreInstances() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.fits")
        let alias = root.appendingPathComponent("alias.fits")
        try primary().write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let a = store(root)
        let b = store(root)
        let resolved = try XCTUnwrap(realpath(source.path, nil))
        defer { free(resolved) }
        let expectedHash = SessionStore.fnv1a64Hex(Data(String(cString: resolved).utf8))
        XCTAssertEqual(try a.recordURL(for: source), try b.recordURL(for: alias))
        XCTAssertEqual(try a.recordURL(for: source).lastPathComponent, "image.fits-\(expectedHash).json")
    }

    #if os(macOS)
    func testRecordNameIsIdenticalAcrossTwoProcesses() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.fits")
        try primary().write(to: source)
        let bundle = Bundle(for: Self.self).bundleURL

        func nameFromChild() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "TheiaKitTests.SessionStoreTests/testRecordNameProbe", bundle.path]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "THEIA_SESSION_RECORD_PROBE_SOURCE": source.path,
                "THEIA_SESSION_RECORD_PROBE_ROOT": root.path,
            ]) { _, new in new }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, text)
            return try XCTUnwrap(text.components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix("SESSION_RECORD_NAME=") })?
                .replacingOccurrences(of: "SESSION_RECORD_NAME=", with: ""))
        }

        let first = try nameFromChild()
        let second = try nameFromChild()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, try store(root).recordURL(for: source).lastPathComponent)
    }

    func testRecordNameProbe() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["THEIA_SESSION_RECORD_PROBE_SOURCE"],
              let root = environment["THEIA_SESSION_RECORD_PROBE_ROOT"] else { return }
        let name = try store(URL(fileURLWithPath: root)).recordURL(for: URL(fileURLWithPath: source)).lastPathComponent
        print("SESSION_RECORD_NAME=\(name)")
    }
    #endif

    func testSaveAndLoadIgnoresTimestampChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("latest.fits")
        let data = primary(date: "2026-09-27")
        try data.write(to: source)
        let persistence = store(root)
        let state = session()
        try persistence.save(state, for: source, fileData: data)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: source.path)
        guard case .restored(let restored) = try persistence.load(for: source, fileData: data) else {
            return XCTFail("Expected saved session after touching the FITS file")
        }
        XCTAssertEqual(restored, state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionState.sidecarURL(for: source).path))
    }

    func testSaveAndLoadPreservesDisplayAndRegionMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("annotated.fits")
        let data = primary()
        try data.write(to: source)
        let persistence = store(root)
        var state = session()
        state.stretch = .power
        state.vmin = -3.5
        state.vmax = 48.25
        state.stretchParameter = 2.75
        state.contour = .init(enabled: true, count: 7, minValue: 2,
                              maxValue: 42, spacing: "log")
        state.regions = [Region(
            shape: .circle(center: .init(x: 12.5, y: 9.5),
                           radius: .init(value: 4, unit: .pixel)),
            frame: .image,
            attributes: ["color": "#ff3300", "text": "target", "tag": "science"]
        )]

        try persistence.save(state, for: source, fileData: data)
        guard case .restored(let loaded) = try persistence.load(for: source, fileData: data) else {
            return XCTFail("Expected saved annotated session")
        }
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.regions.first?.attributes["color"], "#ff3300")
        XCTAssertEqual(loaded.regions.first?.attributes["text"], "target")
        XCTAssertEqual(loaded.regions.first?.attributes["tag"], "science")
    }

    func testCachedIdentityCanBeUsedForRepeatedSaves() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.fits")
        let data = primary()
        try data.write(to: source)
        let persistence = store(root)
        let identity = try SessionStore.identity(for: data)
        var state = session()
        try persistence.save(state, for: source, identity: identity)
        state.selectedPlane = 3
        try persistence.save(state, for: source, identity: identity)
        guard case .restored(let restored) = try persistence.load(for: source, identity: identity) else {
            return XCTFail("Cached identity save should restore")
        }
        XCTAssertEqual(restored, state)
    }

    func testChangedHeaderWithSameFileSizePreservesStaleRecordAndRequiresExplicitRestore() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("latest.fits")
        let oldData = primary(date: "2026-09-27")
        let newData = primary(date: "2026-09-28")
        XCTAssertEqual(oldData.count, newData.count)
        try oldData.write(to: source)
        let persistence = store(root)
        let original = session()
        try persistence.save(original, for: source, fileData: oldData)
        try newData.write(to: source)

        guard case .stale(let pending) = try persistence.load(for: source, fileData: newData) else {
            return XCTFail("A changed header must not apply the session")
        }
        XCTAssertEqual(pending, original)
        let stale = try persistence.staleRecordURL(for: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        guard case .stale = try persistence.load(for: source, fileData: newData) else {
            return XCTFail("Stale restore offer should survive a second open")
        }

        var replacement = original
        replacement.selectedPlane = 7
        let archived = try Data(contentsOf: stale)
        try persistence.save(replacement, for: source, fileData: newData)
        XCTAssertEqual(try Data(contentsOf: stale), archived, "Autosave must preserve the old session")
        guard case .restoredWithStale(let restored, let stillPending) =
                try persistence.load(for: source, fileData: newData) else {
            return XCTFail("A new save should be current while the archive remains offered")
        }
        XCTAssertEqual(restored, replacement)
        XCTAssertEqual(stillPending, original)
    }

    func testCurrentSaveStillSurfacesUndismissedStaleSession() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("latest.fits")
        let oldData = primary(date: "2026-09-27")
        let newData = primary(date: "2026-09-28")
        try oldData.write(to: source)
        let persistence = store(root)
        var oldState = session()
        oldState.vmin = 12
        try persistence.save(oldState, for: source, fileData: oldData)
        try newData.write(to: source)
        guard case .stale = try persistence.load(for: source, fileData: newData) else {
            return XCTFail("Expected original save to become stale")
        }
        var current = session()
        current.vmin = 23
        try persistence.save(current, for: source, fileData: newData)
        guard case .restoredWithStale(let restored, let pending) = try persistence.load(for: source, fileData: newData) else {
            return XCTFail("Current save must not hide undismissed stale session")
        }
        XCTAssertEqual(restored, current)
        XCTAssertEqual(pending, oldState)
    }

    func testSecondMismatchKeepsBothArchivedSessions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("latest.fits")
        let first = primary(date: "2026-09-27")
        let second = primary(date: "2026-09-28")
        let third = primary(date: "2026-09-29")
        try first.write(to: source)
        let persistence = store(root)
        var firstState = session()
        firstState.vmin = 12
        try persistence.save(firstState, for: source, fileData: first)
        try second.write(to: source)
        _ = try persistence.load(for: source, fileData: second)
        var secondState = session()
        secondState.vmin = 23
        try persistence.save(secondState, for: source, fileData: second)
        try third.write(to: source)
        guard case .stale(let pending) = try persistence.load(for: source, fileData: third) else {
            return XCTFail("Second changed file should expose latest archived session")
        }
        XCTAssertEqual(pending, secondState)
        let files = try FileManager.default.contentsOfDirectory(at: store(root).recordURL(for: source).deletingLastPathComponent(),
                                                                 includingPropertiesForKeys: nil)
        let archivedVmins = try files.filter { $0.lastPathComponent.contains("stale") }.map { file -> Double in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let state = try XCTUnwrap(json["session"] as? [String: Any])
            return try XCTUnwrap(state["vmin"] as? Double)
        }
        XCTAssertEqual(Set(archivedVmins), Set([12, 23]))
    }

    func testHeaderInSecondHDUParticipatesInFingerprint() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("multi.fits")
        let oldData = primaryWithPixel() + extensionHDU(date: "2026-09-27")
        let newData = primaryWithPixel() + extensionHDU(date: "2026-09-28")
        try oldData.write(to: source)
        let persistence = store(root)
        try persistence.save(session(), for: source, fileData: oldData)
        try newData.write(to: source)
        guard case .stale = try persistence.load(for: source, fileData: newData) else {
            return XCTFail("A changed extension header must invalidate the saved session")
        }
    }

    func testLegacySidecarLoadsOnlyWithoutStoreRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.fits")
        let data = primary()
        try data.write(to: source)
        let legacy = session()
        try legacy.toJSON().write(to: SessionState.sidecarURL(for: source))
        let persistence = store(root)
        guard case .restored(let restored) = try persistence.load(for: source, fileData: data) else {
            return XCTFail("Expected legacy sidecar")
        }
        XCTAssertEqual(restored, legacy)
        var current = legacy
        current.selectedHDU = 4
        try persistence.save(current, for: source, fileData: data)
        guard case .restored(let afterSave) = try persistence.load(for: source, fileData: data) else {
            return XCTFail("Store entry should take precedence")
        }
        XCTAssertEqual(afterSave, current)
        XCTAssertEqual(try SessionState.fromJSON(Data(contentsOf: SessionState.sidecarURL(for: source))), legacy)
    }

    func testCanonicalPathMismatchMakesCollidingRecordAbsent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.fits")
        let data = primary()
        try data.write(to: source)
        let persistence = store(root)
        try persistence.save(session(), for: source, fileData: data)
        let record = try persistence.recordURL(for: source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        object["canonicalPath"] = "/another/file.fits"
        try JSONSerialization.data(withJSONObject: object).write(to: record)
        guard case .none = try persistence.load(for: source, fileData: data) else {
            return XCTFail("Path mismatch should be treated as absent")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
    }

    private func store(_ root: URL) -> SessionStore {
        SessionStore(paths: AppPaths(platform: .linux, homeDirectory: root, environment: ["XDG_STATE_HOME": root.path]))
    }

    private func session() -> SessionState {
        SessionState(selectedHDU: 0, selectedPlane: 0, stretch: .linear, colorMap: .gray,
                     drawMode: .pan, vmin: 0, vmax: 1, stretchParameter: 1,
                     showWCSGrid: false, showCompass: false, showColorBar: false, regions: [])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func primary(date: String = "2026-09-27") -> Data {
        header(["SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
                "DATE-OBS= '\(date)'", "END"])
    }

    private func extensionHDU(date: String) -> Data {
        header(["XTENSION= 'IMAGE   '", "BITPIX  =                    8", "NAXIS   =                    0",
                "PCOUNT  =                    0", "GCOUNT  =                    1", "DATE-OBS= '\(date)'", "END"])
    }

    private func primaryWithPixel() -> Data {
        let head = header(["SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    1",
                           "NAXIS1  =                    1", "END"])
        return head + Data([42]) + Data(repeating: 0, count: 2879)
    }

    private func header(_ cards: [String]) -> Data {
        let text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        return Data(text.padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
    }
}
