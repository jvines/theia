import CGtk4
import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKRecentFilesTests: XCTestCase {
    @MainActor func testRemoteRecentAppearsInMenuWithHostIdentity() async throws {
        gtk_init()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-remote-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(platform: .linux, homeDirectory: root,
                             environment: ["XDG_STATE_HOME": root.path])
        let recents = GTKRecentFiles(paths: paths)
        let remote = try XCTUnwrap(URL(string: "ssh://jose@cluster.example/data/image.fits"))
        recents.record(remote)
        XCTAssertEqual(recents.urls().first, remote)

        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fixture,
                                      file: try FITSFile(data: Data(contentsOf: fixture)))
        let application = gtk_application_new("cl.jvines.theia.tests",
                                               GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        var opened: URL?
        let window = GTKDocumentWindow(
            application: application, session: session, recentFiles: recents,
            onOpenRecent: { opened = $0 }
        )
        defer { gtk_window_destroy(window.widget) }
        XCTAssertEqual(window.commandMenus.title(for: "file.recent.0"),
                       "image.fits — cluster.example")
        window.commandMenus.activate("file.recent.0")
        XCTAssertEqual(opened, remote)
    }

    @MainActor func testRecentFileAppearsInNativeMenuAndOpenAction() async throws {
        gtk_init()
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let recents = GTKRecentFiles()
        recents.record(url)
        let deadline = Date().addingTimeInterval(2)
        while !recents.urls().contains(url) && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
        }
        let index = try XCTUnwrap(recents.urls().firstIndex(of: url))

        let session = DocumentSession(url: url, file: try FITSFile(data: Data(contentsOf: url)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        var opened = 0
        var openedRecent: URL?
        let window = GTKDocumentWindow(
            application: application, session: session, recentFiles: recents,
            onOpen: { _ in opened += 1 },
            onOpenRecent: { openedRecent = $0 }
        )
        defer { gtk_window_destroy(window.widget) }

        window.commandMenus.activate("file.open")
        window.commandMenus.activate("file.recent.\(index)")
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(openedRecent, url)
    }
}
