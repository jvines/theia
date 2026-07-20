import Foundation

/// Reads a FITS header's 3rd axis to figure out what coordinate the cube planes
/// represent (wavelength, frequency, velocity, channel, …) and how to convert a
/// 0-based plane index to that physical value.
public struct SpectralAxis: Sendable, Equatable {
    public let crval3: Double
    public let crpix3: Double
    public let cdelt3: Double
    public let ctype3: String       // raw CTYPE3 (e.g. "WAVE", "FREQ", "VOPT")
    public let cunit3: String       // raw CUNIT3 (e.g. "Angstrom", "Hz", "m/s")

    /// Convert a 0-based plane index to its physical value.
    public func value(forPlane plane: Int) -> Double {
        // FITS pixels are 1-based: physical = crval + (pix - crpix) * cdelt
        crval3 + (Double(plane) + 1 - crpix3) * cdelt3
    }

    /// All plane values as an array.
    public func values(planeCount: Int) -> [Double] {
        (0..<planeCount).map { value(forPlane: $0) }
    }

    /// Short human label, e.g. "wavelength [Å]" or "frequency [Hz]".
    public var axisLabel: String {
        let kind = Self.kindLabel(ctype3)
        let unit = cunit3.isEmpty ? "" : " [\(cunit3)]"
        return kind + unit
    }

    private static func kindLabel(_ ctype: String) -> String {
        switch ctype.uppercased() {
        case "WAVE", "AWAV":             return "wavelength"
        case "FREQ":                     return "frequency"
        case "VOPT", "VRAD", "VELO":     return "velocity"
        case "ENER":                     return "energy"
        case "AGE":                      return "age"
        case "":                         return "axis 3"
        default:                         return ctype.lowercased()
        }
    }

    /// Build from a FITS header. Returns nil if CRVAL3/CDELT3 are missing
    /// (in which case callers should fall back to plane index).
    public init?(header: FITSHeader) {
        guard let crval = header["CRVAL3"]?.doubleValue,
              let cdelt = header["CDELT3"]?.doubleValue ?? header["CD3_3"]?.doubleValue
        else { return nil }
        self.crval3 = crval
        self.cdelt3 = cdelt
        self.crpix3 = header["CRPIX3"]?.doubleValue ?? 1.0
        self.ctype3 = header["CTYPE3"]?.stringValue ?? ""
        self.cunit3 = header["CUNIT3"]?.stringValue ?? ""
    }
}
