import CGtk4
import Foundation
import XCTest
@testable import TheiaGTK

final class GTKApplicationControllerTests: XCTestCase {
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
