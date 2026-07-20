import Foundation

/// Writes a `FITSImage` as a minimal-header FITS file. Sufficient for round-trip:
/// every standard FITS reader will open the result. Headers are intentionally
/// barebones — for full WCS preservation, callers should supply extra cards.
public enum FITSWriter {
    public enum WriteError: Error {
        case unsupportedPixelType
    }

    /// Write the image, optionally including supplemental header cards (each padded
    /// to 80 chars internally). `extraCards` lets callers add WCS / metadata back.
    public static func write(_ image: FITSImage, to url: URL, extraCards: [String] = []) throws {
        let bitpix: Int
        switch image.pixelType {
        case .uint8:   bitpix = 8
        case .int16:   bitpix = 16
        case .int32:   bitpix = 32
        case .float32: bitpix = -32
        case .float64: bitpix = -64
        }

        // ---- Header ----
        var cards: [String] = []
        cards.append(card("SIMPLE", value: "T", comment: "Standard FITS"))
        cards.append(card("BITPIX", value: "\(bitpix)", comment: nil))
        cards.append(card("NAXIS",  value: "2", comment: nil))
        cards.append(card("NAXIS1", value: "\(image.width)", comment: nil))
        cards.append(card("NAXIS2", value: "\(image.height)", comment: nil))
        if image.bscale != 1.0 {
            cards.append(card("BSCALE", value: String(image.bscale), comment: nil))
        }
        if image.bzero != 0.0 {
            cards.append(card("BZERO", value: String(image.bzero), comment: nil))
        }
        // Preserve the undefined-pixel sentinel. Integer images serialize their raw
        // stored bytes verbatim (see `serializeBigEndianBytes`), so a BLANK card is
        // required for a reader to know which raw value means "undefined".
        if let blank = image.blank {
            cards.append(card("BLANK", value: "\(blank)", comment: "value used for undefined pixels"))
        }
        for raw in extraCards {
            cards.append(pad80(raw))
        }
        cards.append(pad80("END"))

        var headerStr = cards.joined()
        // Pad to a multiple of 2880 bytes.
        if headerStr.count % 2880 != 0 {
            headerStr += String(repeating: " ", count: 2880 - headerStr.count % 2880)
        }
        var bytes = Data(headerStr.utf8)

        // ---- Data ----
        let pixelBytes = image.serializeBigEndianBytes()
        bytes.append(pixelBytes)
        // Pad data to 2880-byte block.
        if bytes.count % 2880 != 0 {
            bytes.append(Data(repeating: 0, count: 2880 - bytes.count % 2880))
        }
        try bytes.write(to: url, options: .atomic)
    }

    private static func card(_ key: String, value: String, comment: String?) -> String {
        // FITS card layout: KEYWORD<padded to 8>= VALUE<right-aligned to col 30> [/ COMMENT]
        let paddedKey = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        let valueField: String
        if value == "T" || value == "F" {
            valueField = "                   \(value)"
        } else {
            // Right-align numeric values in a 20-char field.
            valueField = String(repeating: " ", count: max(0, 20 - value.count)) + value
        }
        var line = "\(paddedKey)= \(valueField)"
        if let comment, !comment.isEmpty {
            line += " / \(comment)"
        }
        return pad80(line)
    }

    private static func pad80(_ s: String) -> String {
        if s.count >= 80 { return String(s.prefix(80)) }
        return s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}

extension FITSImage {
    /// Serialise this image's pixel buffer in big-endian (network) order, matching
    /// the FITS file convention. Reuses the in-memory representation for the float
    /// types since `fromFloat32` already stores big-endian, and recomputes for the
    /// integer types via `physicalValue` (then inverse-scales).
    func serializeBigEndianBytes() -> Data {
        // Fast path: when no scaling is in effect and no BLANK substitution is
        // needed, the raw pixel buffer is already big-endian (FITS storage
        // convention). Return a copy without decoding → re-encoding each pixel.
        if bscale == 1, bzero == 0, blank == nil {
            return Data(pixels)
        }
        let totalPixels = width * height
        switch pixelType {
        case .uint8, .int16, .int32:
            // Integer images store raw big-endian values, and `pixels` is exactly
            // width*height*bpp bytes of that FITS storage. Copy it verbatim so every
            // pixel — including BLANK/undefined ones — round-trips bit-for-bit; the
            // BSCALE/BZERO/BLANK cards emitted above reconstruct physical values on
            // read. Routing pixels through `physicalValue` instead would map BLANK
            // pixels to NaN and then trap in `Int16(nan)` / `Int32(nan)` / `UInt8(nan)`.
            return Data(pixels)
        case .float32:
            var out = Data(capacity: totalPixels * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let v = physicalValue(x: x, y: y)
                    let bits = Float(v).bitPattern.bigEndian
                    withUnsafeBytes(of: bits) { out.append(contentsOf: $0) }
                }
            }
            return out
        case .float64:
            var out = Data(capacity: totalPixels * 8)
            for y in 0..<height {
                for x in 0..<width {
                    let v = physicalValue(x: x, y: y)
                    let bits = v.bitPattern.bigEndian
                    withUnsafeBytes(of: bits) { out.append(contentsOf: $0) }
                }
            }
            return out
        }
    }
}
