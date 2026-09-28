import CGtk4
import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKLightCurveWindowTests: XCTestCase {
    @MainActor func testIndependentWindowUsesSharedNormalizationAndCloses() async throws {
        gtk_init()
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: url, file: try FITSFile(data: Data(contentsOf: url)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let model = LightCurveModel(points: [
            .init(time: 1, flux: 2, err: 0.1),
            .init(time: 2, flux: 4, err: 0.2),
        ], timeLabel: "file index")
        var destroyed = 0
        let window = GTKLightCurveWindow(application: application, model: model,
                                         sourceSession: session) { destroyed += 1 }
        window.present()
        XCTAssertEqual(String(cString: gtk_window_get_title(window.widget)), "Light Curve")
        XCTAssertNil(gtk_window_get_transient_for(window.widget))
        XCTAssertNotNil(gtk_widget_get_parent(UnsafeMutablePointer<GtkWidget>(window.drawArea)))

        gtk_check_button_set_active(window.normalizeButton, 1)
        XCTAssertTrue(window.model.normalized)
        XCTAssertEqual(window.model.displayedPoints.first?.flux, 0.5)
        XCTAssertEqual(String(cString: gtk_label_get_text(window.yLabel)), "flux / median")
        gtk_window_destroy(window.widget)
        XCTAssertEqual(destroyed, 1)
    }
}
