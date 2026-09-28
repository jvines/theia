import CGtk4
import Foundation
import XCTest
@testable import TheiaGTK

final class GTKApplicationControllerTests: XCTestCase {
    @MainActor func testWorkspaceSyncAndStackToolsUseOpenGTKDocuments() async throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-second-\(UUID().uuidString).fits")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let controller = GTKApplicationController(paths: [])
        defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
        ), 1)
        let first = try controller.open(path: fixture.path)
        let second = try controller.open(path: copy.path)
        defer {
            gtk_window_destroy(first.widget)
            gtk_window_destroy(second.widget)
        }

        XCTAssertEqual(first.commandMenus.sectionCount, 14)
        XCTAssertTrue(first.commandMenus.isEnabled("tools.stack.sum"))
        first.commandMenus.activate("sync.colormap")
        XCTAssertEqual(first.commandMenus.title(for: "sync.colormap"), "✓ Match colormap")
        first.session.view.colorMap = .viridis
        XCTAssertEqual(second.session.view.colorMap, .viridis)

        first.commandMenus.activate("tools.stack.sum")
        await first.session.idle()
        XCTAssertNotNil(first.session.derived)
    }

    func testOpeningPathReusesDocumentWindowAndClosesWelcome() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            let controller = GTKApplicationController(paths: [])
            defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
            XCTAssertEqual(g_application_register(
                UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
            ), 1)
            controller.showWelcomeWindow()
            XCTAssertNotNil(controller.welcomeWindow)
            let document = try controller.open(path: fileURL.path)
            XCTAssertEqual(controller.documentWindowCount, 1)
            XCTAssertNil(controller.welcomeWindow)
            let reopened = try controller.open(path: fileURL.path)
            XCTAssertTrue(document === reopened)
            XCTAssertEqual(controller.documentWindowCount, 1)
            gtk_window_destroy(document.widget)
            XCTAssertEqual(controller.documentWindowCount, 0)
        }
    }
}
