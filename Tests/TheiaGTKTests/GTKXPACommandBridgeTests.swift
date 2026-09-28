import CGtk4
import Foundation
import XCTest
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
            XCTAssertTrue(bridge.xpaGet(command: "version", params: "")?.hasPrefix("Theia ") == true)
            XCTAssertNil(bridge.xpaGet(command: "file", params: ""))
            XCTAssertTrue(bridge.xpaSet(command: "file", params: fixture.path, data: nil))
            XCTAssertEqual(bridge.xpaGet(command: "file", params: ""), fixture.path)
            XCTAssertTrue(bridge.xpaSet(command: "scale", params: "log", data: nil))
            XCTAssertEqual(bridge.xpaGet(command: "scale", params: ""), "log")
            XCTAssertFalse(bridge.xpaSet(command: "scale", params: "mode bogus", data: nil))
            XCTAssertEqual(bridge.xpaGet(command: "frame", params: ""), "1")
            for window in controller.documentWindowsForScripting { gtk_window_destroy(window.widget) }
        }
    }
}
