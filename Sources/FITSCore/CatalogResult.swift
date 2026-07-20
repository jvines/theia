import Foundation

public struct GaiaSource: Sendable, Equatable {
    public let ra: Double
    public let dec: Double
    public let gMag: Double?

    public init(ra: Double, dec: Double, gMag: Double? = nil) {
        self.ra = ra
        self.dec = dec
        self.gMag = gMag
    }
}

public enum CatalogResult {
    /// Parses a Gaia TAP CSV response (header row + data rows). Looks up the `ra`,
    /// `dec`, and optionally `phot_g_mean_mag` columns by name (case-insensitive).
    /// Malformed rows are skipped silently.
    public static func parseGaiaCSV(_ csv: String) -> [GaiaSource] {
        let lines = csv.split(whereSeparator: { $0.isNewline })
        guard lines.count >= 2 else { return [] }
        let header = lines[0]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let raIdx = header.firstIndex(of: "ra"),
              let decIdx = header.firstIndex(of: "dec") else { return [] }
        let magIdx = header.firstIndex(of: "phot_g_mean_mag")

        var sources: [GaiaSource] = []
        for line in lines.dropFirst() {
            let fields = line
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count > max(raIdx, decIdx),
                  let ra = Double(fields[raIdx]),
                  let dec = Double(fields[decIdx]) else { continue }
            let mag: Double?
            if let mi = magIdx, mi < fields.count, !fields[mi].isEmpty {
                mag = Double(fields[mi])
            } else {
                mag = nil
            }
            sources.append(GaiaSource(ra: ra, dec: dec, gMag: mag))
        }
        return sources
    }
}
