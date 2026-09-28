import CGtk4
import Foundation
import XCTest
@testable import TheiaGTK

final class GTKScriptingServerTests: XCTestCase {
    func testAuthenticatedRoutesOpenAndControlSharedDocument() async throws {
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
            let token = String(repeating: "a", count: 64)
            let server = GTKScriptingServer(controller: controller, token: token)
            @MainActor func request(_ method: String, _ path: String,
                                    body: String = "", authenticated: Bool = true) throws -> String {
                let auth = authenticated ? "Authorization: Bearer \(token)\r\n" : ""
                let raw = "\(method) \(path) HTTP/1.1\r\n\(auth)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
                let reply = try XCTUnwrap(server.response(for: Data(raw.utf8)))
                return try XCTUnwrap(String(data: reply.data, encoding: .utf8))
            }

            XCTAssertTrue(try request("GET", "/status", authenticated: false).hasPrefix("HTTP/1.1 401"))
            XCTAssertTrue(try request("GET", "/status").contains("\"open\":[]"))
            let openBody = "{\"path\":\"\(fixture.path)\",\"colormap\":\"viridis\"}"
            XCTAssertTrue(try request("POST", "/open", body: openBody).contains("\"id\":0"))
            XCTAssertTrue(try request("GET", "/document/0/info").contains("\"colormap\":\"viridis\""))
            XCTAssertTrue(try request("POST", "/document/0/colormap", body: "{\"name\":\"gray\"}").contains("\"ok\":true"))
            XCTAssertTrue(try request("GET", "/document/0/info").contains("\"colormap\":\"gray\""))
            XCTAssertTrue(try request("POST", "/open", body: openBody).contains("\"id\":0"))
            XCTAssertEqual(controller.documentWindowCount, 1)

            XCTAssertTrue(try request("POST", "/document/0/regions", body: "image\npoint(1,1)").contains("\"n\":1"))
            XCTAssertTrue(try request("GET", "/document/0/regions").contains("point(1, 1)"))
            XCTAssertTrue(try request("POST", "/document/0/regions/clear").contains("\"ok\":true"))
            XCTAssertFalse(try request("GET", "/document/0/regions").contains("point("))
            XCTAssertTrue(try request("POST", "/quit").hasPrefix("HTTP/1.1 200"))
            for window in controller.documentWindowsForScripting { gtk_window_destroy(window.widget) }
        }
    }
}
