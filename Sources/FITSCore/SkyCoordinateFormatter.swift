import Foundation

/// Formats sky coordinates in standard sexagesimal notation.
/// - RA: HH:MM:SS.S (degrees / 15 = hours)
/// - Dec: ±DD:MM:SS.S
public enum SkyCoordinateFormatter {
    public static func formatRA(_ degrees: Double) -> String {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let totalHours = normalized / 15
        var hours = Int(totalHours.rounded(.down))
        var minutes = Int(((totalHours - Double(hours)) * 60).rounded(.down))
        var seconds = ((totalHours - Double(hours)) * 60 - Double(minutes)) * 60
        // Handle rounding-up carry at the displayed precision.
        if (seconds * 10).rounded() >= 600 {
            seconds = 0
            minutes += 1
        }
        if minutes >= 60 {
            minutes = 0
            hours += 1
        }
        if hours >= 24 {
            hours -= 24
        }
        return String(format: "%02d:%02d:%04.1f", hours, minutes, seconds)
    }

    /// Formats a (lon, lat) pair for the given frame: equatorial frames use
    /// sexagesimal RA hours / signed Dec; galactic & ecliptic use decimal degrees
    /// (DS9 convention). Returns labels alongside the values.
    public static func format(lon: Double, lat: Double, frame: CelestialFrame)
        -> (lonLabel: String, lon: String, latLabel: String, lat: String) {
        if frame.isEquatorial {
            return ("α", formatRA(lon), "δ", formatDec(lat))
        }
        let l = ((lon.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let lonLabel = frame == .galactic ? "l" : "λ"
        let latLabel = frame == .galactic ? "b" : "β"
        return (lonLabel, String(format: "%.4f°", l), latLabel, String(format: "%+.4f°", lat))
    }

    public static func formatDec(_ degrees: Double) -> String {
        let sign = degrees < 0 ? "-" : "+"
        let abs = Swift.abs(degrees)
        var deg = Int(abs.rounded(.down))
        var minutes = Int(((abs - Double(deg)) * 60).rounded(.down))
        var seconds = ((abs - Double(deg)) * 60 - Double(minutes)) * 60
        if (seconds * 10).rounded() >= 600 {
            seconds = 0
            minutes += 1
        }
        if minutes >= 60 {
            minutes = 0
            deg += 1
        }
        return String(format: "%@%02d:%02d:%04.1f", sign, deg, minutes, seconds)
    }
}
