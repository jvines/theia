import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class ScriptingHTTPTests: XCTestCase {
    func testParserWaitsForCompleteHeaderAndBody() {
        let partial = Data("POST /open HTTP/1.1\r\nContent-Length: 4\r\n".utf8)
        XCTAssertEqual(ScriptingHTTPRequestParser.parse(partial), .incomplete)

        let header = Data("POST /open HTTP/1.1\r\nContent-Length: 4\r\n\r\n".utf8)
        XCTAssertEqual(ScriptingHTTPRequestParser.parse(header), .incomplete)

        var complete = header
        complete.append(Data("bodyextra".utf8))
        guard case .request(let request) = ScriptingHTTPRequestParser.parse(complete) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.body, Data("body".utf8))
        XCTAssertEqual(request.headerValue("content-length"), "4")
    }

    func testParserRejectsOversizedIncompleteAndCompleteHeadersWith431() {
        let incomplete = Data(repeating: 65, count: ScriptingHTTPRequestParser.maxHeaderBytes + 1)
        XCTAssertEqual(ScriptingHTTPRequestParser.parse(incomplete),
                       .failure(.init(status: 431, message: "header too large")))

        var complete = Data("GET /status HTTP/1.1\r\nX-Pad: ".utf8)
        complete.append(Data(repeating: 65, count: ScriptingHTTPRequestParser.maxHeaderBytes))
        complete.append(Data("\r\n\r\n".utf8))
        XCTAssertEqual(ScriptingHTTPRequestParser.parse(complete),
                       .failure(.init(status: 431, message: "header too large")))
    }

    func testParserRejectsOversizedBodyAndAccumulatedRequestWith413() {
        let declared = Data("POST /open HTTP/1.1\r\nContent-Length: 16777217\r\n\r\n".utf8)
        XCTAssertEqual(ScriptingHTTPRequestParser.parse(declared),
                       .failure(.init(status: 413, message: "request body too large")))

        var accumulated = Data("POST /open HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        accumulated.append(Data(repeating: 65, count: ScriptingHTTPRequestParser.maxHeaderBytes
                                + ScriptingHTTPRequestParser.maxBodyBytes))
        XCTAssertEqual(ScriptingHTTPRequestParser.parse(accumulated),
                       .failure(.init(status: 413, message: "request too large")))
    }

    func testParserRejectsSmugglingContentLengths() {
        for value in ["-1", "+1", "01", "1x", "18446744073709551616"] {
            let raw = Data("POST /open HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n".utf8)
            XCTAssertEqual(ScriptingHTTPRequestParser.parse(raw),
                           .failure(.init(status: 400, message: "invalid content-length")), value)
        }
        let duplicate = Data("POST /open HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n".utf8)
        XCTAssertEqual(ScriptingHTTPRequestParser.parse(duplicate),
                       .failure(.init(status: 400, message: "invalid content-length")))
    }

    func testRouterMatchesAllElevenRoutesAndRejectsExtraSegments() {
        XCTAssertEqual(ScriptingHTTPRouter.resolve(method: "GET", path: "/status"), .status)
        XCTAssertEqual(ScriptingHTTPRouter.resolve(method: "POST", path: "/open"), .open)
        XCTAssertEqual(ScriptingHTTPRouter.resolve(method: "POST", path: "/quit"), .quit)
        let documentRoutes: [(String, String, ScriptingDocumentRoute)] = [
            ("GET", "info", .info),
            ("POST", "stretch", .stretch),
            ("POST", "colormap", .colormap),
            ("POST", "scale", .scale),
            ("POST", "zscale", .zscale),
            ("GET", "regions", .regionsGet),
            ("POST", "regions", .regionsPost),
            ("POST", "regions/clear", .regionsClear),
        ]
        for (method, path, route) in documentRoutes {
            XCTAssertEqual(ScriptingHTTPRouter.resolve(method: method, path: "/document/2/\(path)"),
                           .document(id: 2, route: route))
        }
        XCTAssertEqual(ScriptingHTTPRouter.resolve(method: "GET", path: "/document/2/info/junk"),
                       .document(id: 2, route: nil))
        XCTAssertEqual(ScriptingHTTPRouter.resolve(method: "GET", path: "/document/not-id/info"),
                       .failure(.init(status: 404, message: "bad id")))
        XCTAssertEqual(ScriptingHTTPRouter.resolve(method: "GET", path: "/other"),
                       .failure(.init(status: 404, message: "no route")))
    }

    func testRouteTableListsEveryRoutedEndpointForReference() {
        let routes = ScriptingHTTPRouter.routeTable
        XCTAssertEqual(routes.count, 11)
        XCTAssertEqual(Set(routes.map { "\($0.method) \($0.path)" }).count, 11)
        XCTAssertTrue(routes.contains { $0.method == "POST" && $0.path == "/document/<id>/regions/clear" })
        XCTAssertTrue(routes.allSatisfy { !$0.summary.isEmpty })
    }

    func testRouterDecodesScriptedCommandOrReturnsExistingValidationError() {
        XCTAssertEqual(ScriptingHTTPRouter.command(for: .stretch, body: Data("{\"name\":\"linear\"}".utf8)),
                       .success(.setStretch(.linear)))
        XCTAssertEqual(ScriptingHTTPRouter.command(for: .zscale, body: Data()),
                       .success(.applyScalePreset(.zscale)))
        XCTAssertEqual(ScriptingHTTPRouter.command(for: .scale, body: Data("{}".utf8)),
                       .failure(.init(status: 400, message: "expected {vmin, vmax}")))
    }

    func testScaleRejectsValuesThatOverflowFloat() {
        let body = Data("{\"vmin\":1e40,\"vmax\":1e41}".utf8)
        XCTAssertEqual(ScriptingHTTPRouter.command(for: .scale, body: body),
                       .failure(.init(status: 400, message: "expected {vmin, vmax}")))
    }

    func testOptionalOpenLevelIgnoresValuesThatOverflowFloat() {
        XCTAssertNil(ScriptingHTTPRouter.finiteLevel(1e40))
        XCTAssertEqual(ScriptingHTTPRouter.finiteLevel(42), 42)
    }

    func testOpeningAMissingFileIsNotFoundRatherThanAServerError() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).fits")
        XCTAssertThrowsError(try Data(contentsOf: missing)) { error in
            XCTAssertEqual(ScriptingHTTPRouter.openFailure(error).status, 404)
        }
        XCTAssertEqual(ScriptingHTTPRouter.openFailure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        ).status, 404)
        XCTAssertEqual(ScriptingHTTPRouter.openFailure(CocoaError(.fileReadCorruptFile)).status, 500)
        XCTAssertTrue(ScriptingHTTPRouter.openFailure(CocoaError(.fileReadNoSuchFile))
            .message.hasPrefix("failed to open: "))
    }
}
