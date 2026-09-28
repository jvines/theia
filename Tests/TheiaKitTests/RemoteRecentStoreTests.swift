import Foundation
import XCTest
@testable import TheiaKit

final class RemoteRecentStoreTests: XCTestCase {
    func testRemoteURLsPersistInMostRecentOrderWithoutCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-remote-recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(platform: .linux, homeDirectory: root,
                             environment: ["XDG_STATE_HOME": root.path])
        let store = RemoteRecentStore(paths: paths)
        let first = try XCTUnwrap(URL(string: "ssh://jose@cluster-a/data/image%20one.fits"))
        let second = try XCTUnwrap(URL(string: "ssh://jose@cluster-b/data/image.fits"))
        XCTAssertTrue(try store.urls().isEmpty)

        try store.record(first)
        try store.record(second)
        try store.record(first)
        XCTAssertEqual(try RemoteRecentStore(paths: paths).urls(), [first, second])
        XCTAssertThrowsError(try store.record(URL(fileURLWithPath: "/tmp/local.fits")))
        XCTAssertThrowsError(try store.record(URL(string:
            "ssh://jose:secret@cluster-a/data/image.fits")!))

        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: store.fileURL.path
        )[.posixPermissions] as? NSNumber).intValue
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: store.fileURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
    }

    func testRecentHistoryRetainsOnlyTenLocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-remote-recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(platform: .linux, homeDirectory: root,
                             environment: ["XDG_STATE_HOME": root.path])
        let store = RemoteRecentStore(paths: paths)
        for index in 0..<12 {
            try store.record(URL(string: "ssh://cluster-\(index)/data/image.fits")!)
        }
        let recent = try store.urls()
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.host, "cluster-11")
        XCTAssertEqual(recent.last?.host, "cluster-2")
    }
}
