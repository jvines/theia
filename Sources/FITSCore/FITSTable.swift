import Foundation

/// Common surface for any FITS table extension (BINTABLE or ASCII TABLE) that the
/// UI can render. The two underlying storage formats are very different, but the
/// display layer only needs: column metadata, row count, and a per-cell formatter.
public protocol FITSTable: Sendable {
    var tableColumns: [TableColumnInfo] { get }
    var rowCount: Int { get }
    func displayValue(row: Int, column: Int) -> String
}

public struct TableColumnInfo: Sendable, Equatable {
    public let name: String
    public let format: String
    public let unit: String?
}

extension FITSBinTable: FITSTable {
    public var tableColumns: [TableColumnInfo] {
        columns.map { TableColumnInfo(name: $0.name, format: $0.format, unit: $0.unit) }
    }
}

/// Loads either a BINTABLE or ASCII TABLE from an HDU; returns nil if neither.
public enum FITSTableLoader {
    public static func load(_ hdu: FITSHDU) -> (any FITSTable)? {
        if hdu.xtension == "BINTABLE", let t = FITSBinTable(hdu: hdu) { return t }
        if hdu.xtension == "TABLE", let t = FITSAsciiTable(hdu: hdu) { return t }
        return nil
    }
}
