import SwiftUI
import FITSCore

/// Renders any `FITSTable` (BINTABLE or ASCII TABLE) as a scrollable
/// spreadsheet-like grid. Uses VStack + HStack with fixed column widths so the
/// layout is unambiguous regardless of column count.
struct TableExtensionView: View {
    let table: any FITSTable

    private let columnWidth: CGFloat = 150
    private let rowHeight: CGFloat = 24
    private let headerHeight: CGFloat = 44

    private var columns: [TableColumnInfo] { table.tableColumns }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(0..<table.rowCount, id: \.self) { rowIdx in
                    dataRow(rowIdx)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(table.rowCount) rows × \(columns.count) cols")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(8)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 1) {
                    Text(columns[i].name)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(columns[i].format)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let u = columns[i].unit {
                            Text("[\(u)]")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: columnWidth, height: headerHeight, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .trailing) {
                    Divider()
                }
                .overlay(alignment: .bottom) {
                    Divider()
                }
            }
        }
    }

    private func dataRow(_ rowIdx: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { colIdx in
                Text(table.displayValue(row: rowIdx, column: colIdx))
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .lineLimit(1)
                    .frame(width: columnWidth, height: rowHeight, alignment: .leading)
                    .overlay(alignment: .trailing) { Divider() }
            }
        }
        .background(rowIdx.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.07))
    }
}
