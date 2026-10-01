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
            for window in controller.documentWindowsForScripting { gtk_window_destroy(window.widget) }
        }
    }
}
