import CGtk4
import Foundation
import XCTest
@testable import TheiaGTK

final class GTKFileOpenDialogTests: XCTestCase {
    func testAcceptReturnsSelectedFITSPath() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            var chosenPath: String?
            let dialog = GTKFileOpenDialog(parent: nil) { chosenPath = $0 }
            let file = try XCTUnwrap(g_file_new_for_path(fileURL.path))
            defer { g_object_unref(UnsafeMutableRawPointer(file)) }
            XCTAssertEqual(gtk_file_chooser_set_file(dialog.chooser, file, nil), 1)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
                if let selected = gtk_file_chooser_get_file(dialog.chooser) {
                    g_object_unref(UnsafeMutableRawPointer(selected))
                    break
                }
            }

            theia_gtk_native_dialog_response(dialog.native, GTK_RESPONSE_ACCEPT.rawValue)

            XCTAssertEqual(chosenPath, fileURL.path)
        }
    }

    func testCancelDoesNotReturnPath() async throws {
        await MainActor.run {
            gtk_init()
            var chosenPath: String?
            let dialog = GTKFileOpenDialog(parent: nil) { chosenPath = $0 }

            theia_gtk_native_dialog_response(dialog.native, GTK_RESPONSE_CANCEL.rawValue)

            XCTAssertNil(chosenPath)
        }
    }
}
