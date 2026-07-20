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

/// Thin async wrapper around the ESA Gaia archive TAP `/sync` endpoint.
public actor CatalogClient {
    public static let shared = CatalogClient()

    public init() {}

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
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CatalogError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw CatalogError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let csv = String(data: data, encoding: .utf8) else {
            throw CatalogError.decoding("response is not UTF-8")
        }
        return CatalogResult.parseGaiaCSV(csv)
    }
}
