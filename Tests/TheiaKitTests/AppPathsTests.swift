import Foundation
import XCTest
@testable import TheiaKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class AppPathsTests: XCTestCase {
    func testMacPathsPreserveExistingLocations() throws {
        let paths = AppPaths(
            platform: .macOS,
            homeDirectory: URL(fileURLWithPath: "/Users/observer"),
            environment: [:],
            bundleIdentifier: "cl.jvines.theia"
        )

        XCTAssertEqual(paths.sessionsDirectory.path, "/Users/observer/Library/Application Support/Theia/sessions")
        XCTAssertEqual(paths.logFile.path, "/Users/observer/Library/Logs/cl.jvines.theia/app.log")
        XCTAssertNil(paths.preferencesFile)
        XCTAssertEqual(try paths.tokenFile().path, "/Users/observer/Library/Application Support/cl.jvines.theia/scripting-token")
        XCTAssertEqual(try paths.portFile().path, "/Users/observer/Library/Application Support/cl.jvines.theia/scripting-port")
    }

    func testLinuxXDGPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        let paths = AppPaths(
            platform: .linux,
            homeDirectory: URL(fileURLWithPath: "/home/observer"),
            environment: [
                "XDG_STATE_HOME": "/srv/state",
                "XDG_CONFIG_HOME": "/srv/config",
                "XDG_RUNTIME_DIR": runtime.path,
            ],
            bundleIdentifier: "cl.jvines.theia"
        )

        XCTAssertEqual(paths.sessionsDirectory.path, "/srv/state/theia/sessions")
        XCTAssertEqual(paths.logFile.path, "/srv/state/theia/app.log")
        XCTAssertEqual(paths.preferencesFile?.path, "/srv/config/theia/preferences.json")
        XCTAssertEqual(try paths.tokenFile().path, runtime.appendingPathComponent("theia/scripting-token").path)
        XCTAssertEqual(try paths.portFile().path, runtime.appendingPathComponent("theia/scripting-port").path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: runtime.appendingPathComponent("theia").path)[.posixPermissions] as? Int, 0o700)
    }

    func testLinuxDefaultsIgnoreRelativeXDGHomes() {
        let paths = AppPaths(
            platform: .linux,
            homeDirectory: URL(fileURLWithPath: "/home/observer"),
            environment: ["XDG_STATE_HOME": "relative/state", "XDG_CONFIG_HOME": "", "XDG_RUNTIME_DIR": "relative/run"],
            bundleIdentifier: "cl.jvines.theia"
        )

        XCTAssertEqual(paths.sessionsDirectory.path, "/home/observer/.local/state/theia/sessions")
        XCTAssertEqual(paths.logFile.path, "/home/observer/.local/state/theia/app.log")
        XCTAssertEqual(paths.preferencesFile?.path, "/home/observer/.config/theia/preferences.json")
        XCTAssertEqual(paths.runtimeDirectoryURL?.path, "/tmp/theia-\(getuid())")
    }

    func testRuntimeDirectoryRejectsInsecurePermissionsWithoutChangingThem() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])

        XCTAssertThrowsError(try AppPaths.ensurePrivateDirectory(at: directory, ownerID: getuid()))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o755)
    }

    func testRuntimeDirectoryRejectsSymlink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try AppPaths.ensurePrivateDirectory(at: link, ownerID: getuid()))
    }

    func testRuntimeDirectoryChecksOwner() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        XCTAssertThrowsError(try AppPaths.ensurePrivateDirectory(at: directory, ownerID: getuid() + 1))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppPathsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
