import CGtk4
import Foundation
import Glibc
import XCTest
@testable import TheiaGTK

final class GTKRemoteOpenDialogTests: XCTestCase {
    @MainActor func testAcceptReturnsSSHURLAndClosesDialog() async {
        gtk_init()
        let application = gtk_application_new("cl.jvines.theia.remote-dialog-tests",
                                               GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let parent = UnsafeMutablePointer<GtkWindow>(OpaquePointer(
            gtk_application_window_new(application)!
        ))
        defer { gtk_window_destroy(parent) }
        gtk_window_present(parent)
        var result: String?
        let dialog = GTKRemoteOpenDialog(parent: parent) { result = $0 }
        dialog.present()
        gtk_editable_set_text(dialog.entry, " ssh://jose@cluster.example/data/image.fits ")
        XCTAssertEqual(gtk_widget_activate(dialog.acceptButton), 1)
        for _ in 0..<50 where result == nil {
            _ = g_main_context_iteration(nil, 0)
            usleep(10_000)
        }
        XCTAssertEqual(result, "ssh://jose@cluster.example/data/image.fits")
    }
}
