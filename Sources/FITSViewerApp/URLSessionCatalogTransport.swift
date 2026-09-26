import Foundation
import FITSCore

struct URLSessionCatalogTransport: CatalogTransport {
    func get(_ url: URL, timeout: TimeInterval) async throws -> CatalogHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        return CatalogHTTPResponse(
            data: data,
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
    }
}

enum AppCatalog {
    static let client = CatalogClient(transport: URLSessionCatalogTransport())
}
