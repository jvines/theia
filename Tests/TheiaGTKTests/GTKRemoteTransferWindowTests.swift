import CGtk4
import Glibc
import XCTest
@testable import TheiaGTK

final class GTKRemoteTransferWindowTests: XCTestCase {
    @MainActor func testCancelButtonCancelsOnlyOnce() async {
        gtk_init()
        let application = gtk_application_new("cl.jvines.theia.transfer-window-tests",
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
        var cancellations = 0
        let window = GTKRemoteTransferWindow(
            parent: parent, filename: "image.fits", host: "cluster.example"
        ) { cancellations += 1 }
        window.present()
        XCTAssertFalse(window.isFinished)
        XCTAssertEqual(gtk_widget_activate(window.cancelButton), 1)
        for _ in 0..<50 where cancellations == 0 {
            _ = g_main_context_iteration(nil, 0)
            usleep(10_000)
        }
        XCTAssertTrue(window.isFinished)
        window.dismiss()
        XCTAssertEqual(cancellations, 1)
    }
}
