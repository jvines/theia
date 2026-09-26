import Foundation

public enum CatalogError: Error, LocalizedError {
    case invalidResponse
    case http(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Catalog server returned a non-HTTP response."
        case .http(let code, let body): return "Catalog server returned HTTP \(code): \(body.prefix(200))"
        case .decoding(let why): return "Could not decode catalog response: \(why)"
        }
    }
}

public struct CatalogHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int?

    public init(data: Data, statusCode: Int?) {
        self.data = data
        self.statusCode = statusCode
    }
}

/// The platform shell supplies HTTP so FITSCore never links platform networking.
public protocol CatalogTransport: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> CatalogHTTPResponse
}

/// Thin async wrapper around the ESA Gaia archive TAP `/sync` endpoint.
public actor CatalogClient {
    private let transport: any CatalogTransport

    public init(transport: any CatalogTransport) {
        self.transport = transport
    }

    public func fetchGaia(
        centerRA: Double,
        centerDec: Double,
        radiusDeg: Double,
        limit: Int = 1000
    ) async throws -> [GaiaSource] {
        let adql = CatalogQuery.gaiaConeSearchADQL(
            centerRA: centerRA,
            centerDec: centerDec,
            radiusDeg: radiusDeg,
            limit: limit
        )
        var components = URLComponents(string: "https://gea.esac.esa.int/tap-server/tap/sync")!
        components.queryItems = [
            URLQueryItem(name: "REQUEST", value: "doQuery"),
            URLQueryItem(name: "LANG", value: "ADQL"),
            URLQueryItem(name: "FORMAT", value: "csv"),
            URLQueryItem(name: "QUERY", value: adql),
        ]
        let response = try await transport.get(components.url!, timeout: 30)
        guard let statusCode = response.statusCode else {
            throw CatalogError.invalidResponse
        }
        guard 200..<300 ~= statusCode else {
            throw CatalogError.http(statusCode, String(data: response.data, encoding: .utf8) ?? "")
        }
        guard let csv = String(data: response.data, encoding: .utf8) else {
            throw CatalogError.decoding("response is not UTF-8")
        }
        return CatalogResult.parseGaiaCSV(csv)
    }
}
