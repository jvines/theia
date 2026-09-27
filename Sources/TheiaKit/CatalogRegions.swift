import Foundation
import FITSCore

/// Convert Gaia results to sky-frame markers shared by both front ends.
public enum CatalogRegions {
    public static func fromGaia(_ sources: [GaiaSource]) -> [Region] {
        sources.compactMap { source in
            guard source.ra.isFinite, source.dec.isFinite,
                  (-90...90).contains(source.dec) else { return nil }
            let magnitude = source.gMag?.isFinite == true ? source.gMag : nil
            let radius = max(2, min(8, 16 - (magnitude ?? 20) / 2))
            var attributes: [String: String] = ["color": "cyan", "tag": "Gaia"]
            if let magnitude {
                attributes["text"] = String(format: "G=%.1f", magnitude)
            }
            return Region(
                shape: .circle(center: .init(x: source.ra, y: source.dec),
                               radius: .init(value: radius, unit: .pixel)),
                frame: .fk5,
                attributes: attributes
            )
        }
    }
}
