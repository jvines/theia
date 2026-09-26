import Foundation
import XCTest
@testable import FITSCore

final class CatalogClientTests: XCTestCase {
    func testFetchBuildsGaiaQueryAndParsesCSV() async throws {
        let transport = RecordingCatalogTransport(response: CatalogHTTPResponse(
            data: Data("ra,dec,phot_g_mean_mag\n180.0,-20.0,14.5\n".utf8),
            statusCode: 200
        ))
        let client = CatalogClient(transport: transport)

        let sources = try await client.fetchGaia(
            centerRA: 180, centerDec: -20, radiusDeg: 0.1, limit: 25
        )

        XCTAssertEqual(sources, [GaiaSource(ra: 180, dec: -20, gMag: 14.5)])
        let captured = await transport.lastRequest()
        let (url, timeout) = try XCTUnwrap(captured)
        XCTAssertEqual(url.host, "gea.esac.esa.int")
        XCTAssertEqual(url.path, "/tap-server/tap/sync")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: query.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["REQUEST"], "doQuery")
        XCTAssertEqual(items["LANG"], "ADQL")
        XCTAssertEqual(items["FORMAT"], "csv")
        XCTAssertEqual(items["QUERY"], CatalogQuery.gaiaConeSearchADQL(
            centerRA: 180, centerDec: -20, radiusDeg: 0.1, limit: 25
        ))
        XCTAssertEqual(timeout, 30)
    }

    func testNonHTTPResponseIsRejected() async throws {
        let client = CatalogClient(transport: RecordingCatalogTransport(response: .init(
            data: Data(), statusCode: nil
        )))
        do {
            _ = try await client.fetchGaia(centerRA: 0, centerDec: 0, radiusDeg: 1)
            XCTFail("Expected invalidResponse")
        } catch CatalogError.invalidResponse {
            // Expected.
        }
    }

    func testHTTPFailureIncludesStatusAndBody() async throws {
        let client = CatalogClient(transport: RecordingCatalogTransport(response: .init(
            data: Data("service unavailable".utf8), statusCode: 503
        )))
        do {
            _ = try await client.fetchGaia(centerRA: 0, centerDec: 0, radiusDeg: 1)
            XCTFail("Expected HTTP failure")
        } catch CatalogError.http(let status, let body) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(body, "service unavailable")
        }
    }

    func testInvalidUTF8IsRejected() async throws {
        let client = CatalogClient(transport: RecordingCatalogTransport(response: .init(
            data: Data([0xff]), statusCode: 200
        )))
        do {
            _ = try await client.fetchGaia(centerRA: 0, centerDec: 0, radiusDeg: 1)
            XCTFail("Expected decoding failure")
        } catch CatalogError.decoding(let reason) {
            XCTAssertEqual(reason, "response is not UTF-8")
        }
    }
}

private actor RecordingCatalogTransport: CatalogTransport {
    private let response: CatalogHTTPResponse
    private var request: (URL, TimeInterval)?

    init(response: CatalogHTTPResponse) {
        self.response = response
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> CatalogHTTPResponse {
        request = (url, timeout)
        return response
    }

    func lastRequest() -> (URL, TimeInterval)? { request }
}
