import Foundation
import XCTest
@testable import XPABridge

final class XPABridgeTests: XCTestCase {
    func testLinkedVersion() {
        XCTAssertEqual(XPABridge.version, "2.1.20")
    }

    /// Proves libxpa links and an access point can be created + freed in-process.
    func testCanCreateAccessPoint() {
        XCTAssertTrue(XPABridge.canCreateAccessPoint())
    }

    func testServerReportsWhereItsAccessPointListens() {
        final class Silent: XPAServerDelegate {
            func xpaGet(command: String, params: String) -> Result<String, XPACommandError> { .success("") }
            func xpaSet(command: String, params: String, data: Data?) -> Result<Void, XPACommandError> { .success(()) }
        }
        let delegate = Silent()
        let server = XPAServer(delegate: delegate)
        XCTAssertNil(server.method)
        server.start(accessPoints: [("DS9", "_xpabridge_method_probe")], commands: ["version"])
        defer { server.stop() }
        // Hex ip:port for inet, libxpa's default; the socket's path for unix.
        let method = server.method ?? ""
        let inet = method.range(of: "^[0-9a-f]+:[0-9]+$", options: .regularExpression) != nil
        let unix = method.hasPrefix("/") && FileManager.default.fileExists(atPath: method)
        XCTAssertTrue(inet || unix, "unexpected method: \(method)")
    }
}
