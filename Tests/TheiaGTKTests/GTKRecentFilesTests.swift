import CGtk4
import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKRecentFilesTests: XCTestCase {
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
