import Foundation
import Observation
import FITSCore

public struct HeaderRow: Identifiable, Sendable {
    public let id: Int
    public let card: FITSHeader.Card
}

public struct HeaderCardEdit: Sendable, Equatable {
    public var value: String
    public var comment: String

    public init(value: String, comment: String) {
        self.value = value
        self.comment = comment
    }
}

/// Draft header cards remain associated with their source HDU while selection changes.
@MainActor @Observable public final class HeaderEditor {
    public var search = ""
    public var editing = false
    private var editsByHDU: [Int: [Int: HeaderCardEdit]] = [:]

    public init() {}

    public func filteredRows(in header: FITSHeader) -> [HeaderRow] {
        let rows = header.cards.enumerated().map { HeaderRow(id: $0.offset, card: $0.element) }
        guard !search.isEmpty else { return rows }
        let query = search.lowercased()
        return rows.filter { row in
            let card = row.card
            return card.keyword.lowercased().contains(query)
                || card.value?.displayString.lowercased().contains(query) == true
                || card.comment?.lowercased().contains(query) == true
        }
    }

    public func editCount(for hdu: Int) -> Int { editsByHDU[hdu]?.count ?? 0 }

    public func hasEdit(at index: Int, hdu: Int) -> Bool { editsByHDU[hdu]?[index] != nil }

    public func valueText(for card: FITSHeader.Card, at index: Int, hdu: Int) -> String {
        editsByHDU[hdu]?[index]?.value ?? card.value?.displayString ?? ""
    }

    public func commentText(for card: FITSHeader.Card, at index: Int, hdu: Int) -> String {
        editsByHDU[hdu]?[index]?.comment ?? card.comment ?? ""
    }

    public func setValue(_ value: String, for card: FITSHeader.Card, at index: Int, hdu: Int) {
        let comment = commentText(for: card, at: index, hdu: hdu)
        var edits = editsByHDU[hdu] ?? [:]
        edits[index] = HeaderCardEdit(value: value, comment: comment)
        editsByHDU[hdu] = edits
    }

    public func setComment(_ comment: String, for card: FITSHeader.Card, at index: Int, hdu: Int) {
        let value = valueText(for: card, at: index, hdu: hdu)
        var edits = editsByHDU[hdu] ?? [:]
        edits[index] = HeaderCardEdit(value: value, comment: comment)
        editsByHDU[hdu] = edits
    }

    public func clearEdits(for hdu: Int) { editsByHDU[hdu] = nil }

    /// FITSWriter supplies the structural cards for the displayed image.
    public func serializedExtraCards(from header: FITSHeader, hdu: Int) -> [String] {
        let skip: Set<String> = ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "NAXIS3", "END"]
        return header.cards.enumerated().compactMap { index, card in
            guard !skip.contains(card.keyword) else { return nil }
            return FITSHeader.serializeCard(
                keyword: card.keyword,
                valueText: valueText(for: card, at: index, hdu: hdu),
                commentText: commentText(for: card, at: index, hdu: hdu)
            )
        }
    }
}
