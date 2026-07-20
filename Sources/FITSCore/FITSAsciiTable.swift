import Foundation

/// FITS ASCII TABLE extension (`XTENSION='TABLE'`). The data is plain ASCII text;
/// each field occupies a fixed character range within each row, defined by `TBCOLn`
/// (1-based start column) and `TFORMn` (FORTRAN-style format giving the width).
public struct FITSAsciiTable: Sendable {
    public struct Column: Sendable, Equatable {
        public let name: String
        public let format: String
        public let unit: String?
        public let startColumn: Int   // 0-based byte offset within row
        public let width: Int
    }

    public let columns: [Column]
    public let rowCount: Int
    public let bytesPerRow: Int
    public let data: Data

    public init?(hdu: FITSHDU) {
        guard hdu.xtension == "TABLE",
              hdu.naxis == 2,
              let nFields = hdu.header["TFIELDS"]?.intValue,
              nFields > 0 else { return nil }
        let naxes = hdu.axes
        let bytesPerRow = naxes[0]
        let rowCount = naxes[1]

        var cols: [Column] = []
        for f in 1...nFields {
            guard let tbcol = hdu.header["TBCOL\(f)"]?.intValue,
                  let formRaw = hdu.header["TFORM\(f)"]?.stringValue?
                    .trimmingCharacters(in: .whitespaces) else { return nil }
            let width = Self.parseWidth(formRaw)
            let name = hdu.header["TTYPE\(f)"]?.stringValue?
                .trimmingCharacters(in: .whitespaces) ?? "col\(f)"
            let unit = hdu.header["TUNIT\(f)"]?.stringValue?
                .trimmingCharacters(in: .whitespaces)
            cols.append(Column(
                name: name,
                format: formRaw,
                unit: unit?.isEmpty == true ? nil : unit,
                startColumn: tbcol - 1,
                width: width
            ))
        }

        let total = bytesPerRow * rowCount
        guard hdu.data.count >= total else { return nil }
        self.columns = cols
        self.rowCount = rowCount
        self.bytesPerRow = bytesPerRow
        self.data = hdu.data.prefix(total)
    }

    public func displayValue(row: Int, column: Int) -> String {
        guard row >= 0, row < rowCount,
              column >= 0, column < columns.count else { return "" }
        let col = columns[column]
        // Guard against a malformed TBCOLn: a negative start (startColumn < 0)
        // drops cellStart below data.startIndex, and a start past the row width
        // makes cellStart > cellEnd — both trap the raw `subdata(in:)` range.
        guard col.startColumn >= 0, col.startColumn < bytesPerRow, col.width > 0 else { return "" }
        let rowStart = data.startIndex + row * bytesPerRow
        let cellStart = rowStart + col.startColumn
        let cellEnd = min(cellStart + col.width, rowStart + bytesPerRow)
        let bytes = data.subdata(in: cellStart..<cellEnd)
        let raw = String(data: bytes, encoding: .ascii) ?? ""
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// Extracts the field width from a FORTRAN TFORM string like `D25.16`, `E15.7`,
    /// `I8`, `A10`, `Fw.d`. Defaults to 0 on parse failure.
    private static func parseWidth(_ s: String) -> Int {
        var idx = s.startIndex
        guard idx < s.endIndex else { return 0 }
        // skip the leading type char
        idx = s.index(after: idx)
        var digits = ""
        while idx < s.endIndex, s[idx].isNumber {
            digits.append(s[idx])
            idx = s.index(after: idx)
        }
        return Int(digits) ?? 0
    }
}

extension FITSAsciiTable: FITSTable {
    public var tableColumns: [TableColumnInfo] {
        columns.map { TableColumnInfo(name: $0.name, format: $0.format, unit: $0.unit) }
    }
}
