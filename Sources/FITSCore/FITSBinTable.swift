import Foundation

/// Parsed BINTABLE extension. Holds enough metadata to format any cell on demand.
/// Variable-length array fields (P, Q descriptors) are currently parsed only as
/// their 8-byte descriptors — the heap area is not yet followed.
public struct FITSBinTable: Sendable {
    public enum FieldType: Sendable, Equatable {
        case logical                 // L, 1 byte
        case byte                    // B (unsigned), 1 byte
        case int16                   // I, 2 bytes
        case int32                   // J, 4 bytes
        case int64                   // K, 8 bytes
        case float32                 // E, 4 bytes
        case float64                 // D, 8 bytes
        case character               // A (1 byte each; repeatCount = string length)
        case unsupported(Character)  // X, C, M, P, Q… — bytes still skipped correctly
    }

    public struct Column: Sendable, Equatable {
        public let name: String        // TTYPEn or "col<n>"
        public let format: String      // raw TFORMn
        public let unit: String?       // TUNITn
        public let type: FieldType
        public let repeatCount: Int    // count from TFORMn (defaults to 1)
        public let byteOffset: Int     // within a row
        public let byteSize: Int       // total bytes for this field within a row
    }

    public let columns: [Column]
    public let rowCount: Int
    public let bytesPerRow: Int
    public let data: Data              // exactly rowCount × bytesPerRow

    public init?(hdu: FITSHDU) {
        guard hdu.xtension == "BINTABLE",
              hdu.naxis == 2,
              let nFields = hdu.header["TFIELDS"]?.intValue,
              nFields > 0, nFields <= 9999 else { return nil }
        let naxes = hdu.axes
        guard naxes.count == 2, naxes[0] >= 0, naxes[1] >= 0 else { return nil }
        let bytesPerRow = naxes[0]
        let rowCount = naxes[1]

        var cols: [Column] = []
        var offset = 0
        for f in 1...nFields {
            guard let formRaw = hdu.header["TFORM\(f)"]?.stringValue?
                .trimmingCharacters(in: .whitespaces)
            else { return nil }
            let parsed = Self.parseTFORM(formRaw)
            let name = hdu.header["TTYPE\(f)"]?.stringValue?
                .trimmingCharacters(in: .whitespaces) ?? "col\(f)"
            let unit = hdu.header["TUNIT\(f)"]?.stringValue?
                .trimmingCharacters(in: .whitespaces)
            let byteSize = parsed.bytesPerElement * parsed.count
            cols.append(Column(
                name: name,
                format: formRaw,
                unit: unit?.isEmpty == true ? nil : unit,
                type: parsed.type,
                repeatCount: parsed.count,
                byteOffset: offset,
                byteSize: byteSize
            ))
            offset += byteSize
        }
        // Don't enforce offset == bytesPerRow strictly (unsupported types may differ);
        // just trust BINTABLE-declared bytes per row for indexing.

        let totalResult = bytesPerRow.multipliedReportingOverflow(by: rowCount)
        guard !totalResult.overflow else { return nil }
        let total = totalResult.partialValue
        guard hdu.data.count >= total else { return nil }
        self.columns = cols
        self.rowCount = rowCount
        self.bytesPerRow = bytesPerRow
        self.data = hdu.data.prefix(total)
    }

    /// Returns a formatted display string for the cell at (`row`, `column`).
    public func displayValue(row: Int, column: Int) -> String {
        guard row >= 0, row < rowCount,
              column >= 0, column < columns.count else { return "" }
        let col = columns[column]
        // Guard against column geometry (byteOffset/byteSize accumulated from the
        // TFORMs) that overruns the declared row width — the per-type reads below
        // would otherwise index past the row/data end and trap. Phrased to avoid
        // overflow in the bound itself (byteOffset ∈ [0, bytesPerRow]).
        guard col.byteOffset >= 0,
              col.byteOffset <= bytesPerRow,
              col.byteSize > 0,
              col.byteSize <= bytesPerRow - col.byteOffset else { return "" }
        let base = data.startIndex + row * bytesPerRow + col.byteOffset

        switch col.type {
        case .logical:
            return col.repeatCount > 1 ? "[\(col.repeatCount) bools]" : (data[base] == 0x54 ? "T" : "F")
        case .byte:
            return col.repeatCount > 1 ? "[\(col.repeatCount) bytes]" : "\(data[base])"
        case .int16:
            return formatInts(base: base, count: col.repeatCount, size: 2) { Int(readInt16(at: $0)) }
        case .int32:
            return formatInts(base: base, count: col.repeatCount, size: 4) { Int(readInt32(at: $0)) }
        case .int64:
            return formatInts(base: base, count: col.repeatCount, size: 8) { Int(readInt64(at: $0)) }
        case .float32:
            return formatFloats(base: base, count: col.repeatCount, size: 4) { Double(readFloat32(at: $0)) }
        case .float64:
            return formatFloats(base: base, count: col.repeatCount, size: 8) { readFloat64(at: $0) }
        case .character:
            let bytes = data.subdata(in: base..<(base + col.repeatCount))
            let s = String(data: bytes, encoding: .ascii) ?? ""
            return s.trimmingCharacters(in: .whitespaces)
        case .unsupported(let ch):
            return "<\(String(ch)) ×\(col.repeatCount)>"
        }
    }

    // MARK: - TFORM parsing

    private struct ParsedTFORM {
        let count: Int
        let type: FieldType
        let bytesPerElement: Int
    }

    private static func parseTFORM(_ raw: String) -> ParsedTFORM {
        // Pattern: leading digits = repeat count (default 1), then a type char.
        var idx = raw.startIndex
        var digits = ""
        while idx < raw.endIndex, raw[idx].isNumber {
            digits.append(raw[idx])
            idx = raw.index(after: idx)
        }
        let count = digits.isEmpty ? 1 : (Int(digits) ?? 1)
        let typeChar: Character = idx < raw.endIndex ? raw[idx] : "X"

        switch typeChar {
        case "L": return .init(count: count, type: .logical, bytesPerElement: 1)
        case "B": return .init(count: count, type: .byte, bytesPerElement: 1)
        case "I": return .init(count: count, type: .int16, bytesPerElement: 2)
        case "J": return .init(count: count, type: .int32, bytesPerElement: 4)
        case "K": return .init(count: count, type: .int64, bytesPerElement: 8)
        case "E": return .init(count: count, type: .float32, bytesPerElement: 4)
        case "D": return .init(count: count, type: .float64, bytesPerElement: 8)
        case "A": return .init(count: count, type: .character, bytesPerElement: 1)
        default:  return .init(count: count, type: .unsupported(typeChar), bytesPerElement: 1)
        }
    }

    // MARK: - Big-endian primitive reads

    private func readInt16(at i: Int) -> Int16 {
        Int16(bitPattern: (UInt16(data[i]) << 8) | UInt16(data[i + 1]))
    }
    private func readInt32(at i: Int) -> Int32 {
        var u: UInt32 = 0
        for k in 0..<4 { u = (u << 8) | UInt32(data[i + k]) }
        return Int32(bitPattern: u)
    }
    private func readInt64(at i: Int) -> Int64 {
        var u: UInt64 = 0
        for k in 0..<8 { u = (u << 8) | UInt64(data[i + k]) }
        return Int64(bitPattern: u)
    }
    private func readFloat32(at i: Int) -> Float {
        var u: UInt32 = 0
        for k in 0..<4 { u = (u << 8) | UInt32(data[i + k]) }
        return Float(bitPattern: u)
    }
    private func readFloat64(at i: Int) -> Double {
        var u: UInt64 = 0
        for k in 0..<8 { u = (u << 8) | UInt64(data[i + k]) }
        return Double(bitPattern: u)
    }

    private func formatInts(base: Int, count: Int, size: Int, read: (Int) -> Int) -> String {
        if count == 1 { return "\(read(base))" }
        let preview = (0..<min(count, 3)).map { read(base + $0 * size) }
        let trailing = count > 3 ? ", …" : ""
        return "[" + preview.map(String.init).joined(separator: ", ") + trailing + "]"
    }

    private func formatFloats(base: Int, count: Int, size: Int, read: (Int) -> Double) -> String {
        if count == 1 { return String(format: "%g", read(base)) }
        let preview = (0..<min(count, 3)).map { read(base + $0 * size) }
        let trailing = count > 3 ? ", …" : ""
        return "[" + preview.map { String(format: "%g", $0) }.joined(separator: ", ") + trailing + "]"
    }
}
