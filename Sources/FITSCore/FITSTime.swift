import Foundation

/// Extracts an observation time from a FITS header. Tries (in order) BJD-OBS,
/// MJD-OBS, JD-OBS, then DATE-OBS (ISO 8601). Returns MJD for everything except
/// BJD, which is returned as BJD - 2400000.5 (i.e. also MJD-like, ~consistent
/// ordering for plotting).
public enum FITSTime {
    /// Returns `(value, label)` where label describes the time system in use
    /// for the y-axis title (e.g. "MJD", "BJD-2400000.5"). nil if no time
    /// keyword is present.
    public static func observationMJD(header: FITSHeader) -> (mjd: Double, label: String)? {
        if let bjd = header["BJD-OBS"]?.doubleValue {
            return (bjd - 2_400_000.5, "BJD-2400000.5")
        }
        if let mjd = header["MJD-OBS"]?.doubleValue { return (mjd, "MJD") }
        if let jd  = header["JD-OBS"]?.doubleValue  { return (jd - 2_400_000.5, "JD-2400000.5") }
        if let date = header["DATE-OBS"]?.stringValue {
            // DATE-OBS may be "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SS[.fff]". Optional
            // separate TIME-OBS card augments date-only strings.
            let timeText = header["TIME-OBS"]?.stringValue
            if let d = parseISODate(date, time: timeText) {
                return (mjdFromDate(d), "MJD")
            }
        }
        return nil
    }

    private static func parseISODate(_ s: String, time: String?) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var iso = trimmed
        if !iso.contains("T") {
            iso += "T" + (time?.trimmingCharacters(in: .whitespaces) ?? "00:00:00")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: iso + (iso.hasSuffix("Z") ? "" : "Z")) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso + (iso.hasSuffix("Z") ? "" : "Z"))
    }

    private static func mjdFromDate(_ d: Date) -> Double {
        // Unix epoch (1970-01-01T00:00:00Z) = JD 2440587.5 = MJD 40587.
        let unixSeconds = d.timeIntervalSince1970
        return 40587.0 + unixSeconds / 86_400.0
    }
}
