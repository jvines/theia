import CGtk4
import Foundation
import XCTest
import XPABridge
@testable import TheiaGTK

final class GTKXPACommandBridgeTests: XCTestCase {
    func testDS9CommandsUseSharedLinuxSession() async throws {
        try await MainActor.run {
            gtk_init()
            let fixture = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            let controller = GTKApplicationController(paths: [])
            defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
            XCTAssertEqual(g_application_register(
                UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
            ), 1)
            let bridge = GTKXPACommandBridge(controller: controller)
            func succeeded(_ result: Result<Void, XPACommandError>) -> Bool {
                if case .success = result { return true }
                return false
            }
            XCTAssertTrue((try? bridge.xpaGet(command: "version", params: "").get())?
                .hasPrefix("Theia ") == true)
            XCTAssertEqual(bridge.xpaGet(command: "file", params: ""),
                           .failure(XPACommandError("no image is open")))
            XCTAssertTrue(succeeded(bridge.xpaSet(command: "file", params: fixture.path, data: nil)))
            XCTAssertEqual(bridge.xpaGet(command: "file", params: ""), .success(fixture.path))
            XCTAssertTrue(succeeded(bridge.xpaSet(command: "scale", params: "log", data: nil)))
            XCTAssertEqual(bridge.xpaGet(command: "scale", params: ""), .success("log"))
            XCTAssertFalse(succeeded(bridge.xpaSet(command: "scale", params: "mode bogus", data: nil)))
            XCTAssertTrue(succeeded(bridge.xpaSet(command: "cmap", params: "Heat", data: nil)))
            XCTAssertEqual(bridge.xpaGet(command: "cmap", params: ""), .success("heat"))
            XCTAssertEqual(bridge.xpaGet(command: "zscale", params: "contrast"), .success("0.25"))
            XCTAssertEqual(bridge.xpaGet(command: "frame", params: ""), .success("1"))

            // ds9 loads `file` into the current frame: one window, same frame,
            // and the frame keeps its scale and colour map.
            let other = try XCTUnwrap(Bundle.module.url(
                forResource: "multi_hdu", withExtension: "fits", subdirectory: "Fixtures"
            ))
            XCTAssertTrue(succeeded(bridge.xpaSet(command: "file", params: other.path, data: nil)))
            XCTAssertEqual(controller.documentWindowCount, 1)
            XCTAssertEqual(bridge.xpaGet(command: "file", params: ""), .success(other.path))
            XCTAssertEqual(bridge.xpaGet(command: "frame", params: ""), .success("1"))
            XCTAssertEqual(bridge.xpaGet(command: "scale", params: ""), .success("log"))
            XCTAssertEqual(bridge.xpaGet(command: "cmap", params: ""), .success("heat"))
            // "new" asks for another frame.
            XCTAssertTrue(succeeded(bridge.xpaSet(command: "file", params: "new \(fixture.path)", data: nil)))
            XCTAssertEqual(controller.documentWindowCount, 2)
            // `xpaset ds9 fits < image.fits`: the bytes load into the current
            // frame, every time, under the name stdin.
            let image = try Data(contentsOf: fixture)
            for _ in 0..<2 {
                XCTAssertTrue(succeeded(bridge.xpaSet(command: "fits", params: "", data: image)))
                XCTAssertEqual(controller.documentWindowCount, 2)
                XCTAssertEqual(bridge.xpaGet(command: "file", params: ""), .success("stdin"))
            }
            XCTAssertFalse(succeeded(bridge.xpaSet(command: "fits", params: "",
                                                   data: Data("SIMPLE  = garbage".utf8))))
            for window in controller.documentWindowsForScripting { gtk_window_destroy(window.widget) }
        }
    }
}
