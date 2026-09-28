import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class CurlCatalogTransportTests: XCTestCase {
    func testTimeoutStopsSlowRequest() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
            import socket, time
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            print(listener.getsockname()[1], flush=True)
            connection, _ = listener.accept()
            connection.recv(4096)
            time.sleep(1)
            connection.close()
            """]
        let output = Pipe()
        server.standardOutput = output
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        let portText = String(data: output.fileHandleForReading.availableData,
                              encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try XCTUnwrap(portText.flatMap(UInt16.init))

        let started = Date()
        do {
            _ = try await CurlCatalogTransport().get(
                URL(string: "http://127.0.0.1:\(port)/slow")!, timeout: 0.1
            )
            XCTFail("Slow catalog response should time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("timeout"),
                          "Unexpected curl error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testLocalHTTPStatusAndBodyWithoutFoundationNetworking() async throws {
        let portFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-curl-test-\(UUID().uuidString).port")
        defer { try? FileManager.default.removeItem(at: portFile) }
        let server = ScriptingSocketServer(portFileURL: portFile, portRange: 53_000...53_100) { request in
            let text = String(data: request, encoding: .utf8) ?? ""
            let status = text.hasPrefix("GET /unavailable ") ? "503 Service Unavailable" : "200 OK"
            let body = status.hasPrefix("503") ? "busy" : "hello"
            return ScriptingSocketReply(data: Data(
                "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8
            ))
        }
        let port = try server.start()
        defer { server.stop() }
        let transport = CurlCatalogTransport()

        let success = try await transport.get(URL(string: "http://127.0.0.1:\(port)/catalog")!, timeout: 2)
        XCTAssertEqual(success.statusCode, 200)
        XCTAssertEqual(String(data: success.data, encoding: .utf8), "hello")

        let failure = try await transport.get(URL(string: "http://127.0.0.1:\(port)/unavailable")!, timeout: 2)
        XCTAssertEqual(failure.statusCode, 503)
        XCTAssertEqual(String(data: failure.data, encoding: .utf8), "busy")
    }
}
