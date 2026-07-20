import Foundation

/// FITS headers are stored as 80-character ASCII card images, grouped in 2880-byte blocks,
/// terminated by an `END` card. This is a minimal pure-Swift parser for MVP.
public struct FITSHeader: Sendable {
    public let cards: [Card]
    private let lookup: [String: Int]

    public init(cards: [Card]) {
        self.cards = cards
        var lookup: [String: Int] = [:]
        lookup.reserveCapacity(cards.count)
        for (i, card) in cards.enumerated() where lookup[card.keyword] == nil {
            lookup[card.keyword] = i
        }
        self.lookup = lookup
    }

    public struct Card: Sendable {
        public let keyword: String
        public let value: Value?
        public let comment: String?
    }

    public enum Value: Sendable {
        case bool(Bool)
        case integer(Int)
        case float(Double)
        case string(String)

        public var intValue: Int? {
            if case .integer(let v) = self { return v }
            if case .float(let v) = self {
                // A NaN/±inf or out-of-range float traps `Int(v)`. Reject those
                // (upper bound is `<`, since Double(Int.max) rounds up to 2^63,
                // which `Int(_:)` still can't represent).
                guard v.isFinite, v >= Double(Int.min), v < Double(Int.max) else { return nil }
                return Int(v)
            }
            return nil
        }
        public var stringValue: String? {
            if case .string(let v) = self { return v }
            return nil
        }
        public var doubleValue: Double? {
            switch self {
            case .integer(let v): return Double(v)
            case .float(let v): return v
            default: return nil
            }
        }

        /// Human-readable representation suitable for header tables.
        public var displayString: String {
            switch self {
            case .integer(let v): return String(v)
            case .float(let v): return String(v)
            case .bool(let v): return v ? "T" : "F"
            case .string(let v): return v
            }
        }
    }

    /// Reconstruct an 80-char FITS card line from the keyword + an edited value/comment
    /// pair. The value is encoded based on simple heuristics:
    ///   - "T" / "F" → bool
    ///   - parseable Int → integer (right-aligned in cols 11–30)
    ///   - parseable Double → float
    ///   - otherwise → single-quoted string
    /// Returns nil if `keyword` doesn't fit FITS rules.
    public static func serializeCard(keyword: String, valueText: String, commentText: String) -> String? {
        let key = keyword.uppercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        // Keys longer than 8 chars or containing spaces can only be written via the
        // HIERARCH convention (e.g. ESO cards); everything else uses the standard
        // column layout. Without this, editing+saving a HIERARCH card dropped it.
        let isHierarch = key.count > 8 || key.contains(" ")

        if !isHierarch, ["COMMENT", "HISTORY"].contains(key) {
            let paddedKey = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            let body = commentText.isEmpty ? valueText : commentText
            return pad80("\(paddedKey) \(body)")
        }

        // Encode the value token; numeric/bool tokens are right-aligned to col 30
        // in the standard layout, strings are left-aligned and quoted.
        let trimmed = valueText.trimmingCharacters(in: .whitespaces)
        let token: String
        let rightAlign: Bool
        if trimmed == "T" || trimmed == "F" {
            token = trimmed; rightAlign = true
        } else if Int(trimmed) != nil || Double(trimmed) != nil {
            token = trimmed; rightAlign = true
        } else {
            var s = trimmed.replacingOccurrences(of: "'", with: "''")   // double embedded quotes
            if s.count < 8 { s = s.padding(toLength: 8, withPad: " ", startingAt: 0) }
            token = "'\(s)'"; rightAlign = false
        }

        let head: String
        let valueField: String
        if isHierarch {
            head = "HIERARCH \(key) = "
            valueField = token   // HIERARCH cards don't pad to the column-30 grid
        } else {
            head = "\(key.padding(toLength: 8, withPad: " ", startingAt: 0))= "
            valueField = rightAlign
                ? String(repeating: " ", count: Swift.max(0, 20 - token.count)) + token
                : token
        }
        var line = "\(head)\(valueField)"
        if !commentText.isEmpty {
            line += " / \(commentText)"
        }
        return pad80(line)
    }

    private static func pad80(_ s: String) -> String {
        if s.count >= 80 { return String(s.prefix(80)) }
        return s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    public subscript(_ keyword: String) -> Value? {
        guard let idx = lookup[keyword] else { return nil }
        return cards[idx].value
    }

    /// Total data block size in bytes, or nil if the declared dimensions are
    /// invalid / overflow / exceed a sane upper bound. The hard cap (`maxBytes`)
    /// prevents a crafted header with absurd NAXIS values from making downstream
    /// arithmetic wrap; we treat anything beyond ~32 GP as bogus.
    public func dataLengthBytes(maxBytes: Int = 1 << 36) -> Int? {
        let bitpix = self["BITPIX"]?.intValue ?? 0
        let naxis = self["NAXIS"]?.intValue ?? 0
        guard naxis > 0 else { return 0 }
        // Reject silly NAXIS counts up front (legal FITS is 0–999, but realistic
        // is ≤ 4 — anything else is almost certainly malformed/hostile).
        guard naxis <= 16 else { return nil }

        let pcount = self["PCOUNT"]?.intValue ?? 0
        let gcount = self["GCOUNT"]?.intValue ?? 1
        guard pcount >= 0, gcount >= 0 else { return nil }

        // Random Groups convention: NAXIS1 == 0 together with GROUPS=T is a signal,
        // not empty data — the group array product then runs from axis 2. Any other
        // zero axis genuinely means no data.
        var isRandomGroups = false
        if case .bool(true)? = self["GROUPS"], (self["NAXIS1"]?.intValue ?? -1) == 0 {
            isRandomGroups = true
        }

        var pixels = 1
        let firstAxis = isRandomGroups ? 2 : 1
        if firstAxis <= naxis {
            for i in firstAxis...naxis {
                guard let dim = self["NAXIS\(i)"]?.intValue, dim >= 0 else { return nil }
                if dim == 0 { return 0 }
                let r = pixels.multipliedReportingOverflow(by: dim)
                if r.overflow { return nil }
                pixels = r.partialValue
            }
        }
        let bytesPerPixel = abs(bitpix) / 8
        guard bytesPerPixel > 0 else { return nil }

        // Nbytes = |BITPIX|/8 × GCOUNT × (PCOUNT + Π NAXISn). For a standard array
        // (PCOUNT=0, GCOUNT=1) this reduces to the plain pixel product; carrying
        // PCOUNT/GCOUNT also lets a heap-bearing BINTABLE's data length (and hence
        // the next HDU's offset) come out right.
        let (groupElems, o1) = pcount.addingReportingOverflow(pixels)
        guard !o1 else { return nil }
        let (groups, o2) = gcount.multipliedReportingOverflow(by: groupElems)
        guard !o2 else { return nil }
        let (total, o3) = groups.multipliedReportingOverflow(by: bytesPerPixel)
        guard !o3, total >= 0, total <= maxBytes else { return nil }
        return total
    }

    /// Parse a header starting at `offset`. Returns the parsed header and the byte offset
    /// where the data section begins (i.e., one past the end of the header block).
    static func parse(in data: Data, at offset: Int) throws -> (FITSHeader, Int)? {
        let blockSize = 2880
        let cardSize = 80
        var cursor = offset
        var cards: [Card] = []
        while cursor + blockSize <= data.count {
            let block = data.subdata(in: cursor..<cursor + blockSize)
            cursor += blockSize
            var sawEnd = false
            for i in 0..<(blockSize / cardSize) {
                let cardData = block.subdata(in: (i * cardSize)..<((i + 1) * cardSize))
                guard let cardString = String(data: cardData, encoding: .ascii) else {
                    throw FITSError.invalidHeader("non-ASCII card at offset \(cursor)")
                }
                // END is detected on the 8-char keyword field only. Comparing the
                // whole trimmed card would let a blank-keyword card whose body is
                // "END" terminate the header early (wrong data offset).
                let keyword = String(cardString.prefix(8)).trimmingCharacters(in: .whitespaces)
                if keyword == "END" {
                    sawEnd = true
                    break
                }
                if keyword == "CONTINUE" {
                    // FITS long-string convention: fold this continuation into the
                    // preceding string value (dropping its trailing `&` marker).
                    appendContinuation(cardString, to: &cards)
                    continue
                }
                if let card = parseCard(cardString) {
                    cards.append(card)
                }
            }
            if sawEnd { return (FITSHeader(cards: cards), cursor) }
        }
        return nil
    }

    /// Folds a `CONTINUE` card's string into the preceding string value, per the
    /// FITS long-string convention (the continued value ends with a `&` marker).
    private static func appendContinuation(_ raw: String, to cards: inout [Card]) {
        let body = String(raw.dropFirst(8))   // text after the "CONTINUE" keyword
        let (value, comment) = parseValueAndComment(body)
        guard case .string(let segment)? = value,
              let last = cards.last, case .string(let prev)? = last.value else {
            return   // nothing sensible to continue — drop the orphan CONTINUE card
        }
        let base = prev.hasSuffix("&") ? String(prev.dropLast()) : prev
        cards[cards.count - 1] = Card(
            keyword: last.keyword,
            value: .string(base + segment),
            comment: last.comment ?? comment
        )
    }

    private static func parseCard(_ raw: String) -> Card? {
        // ESO/HIERARCH convention: `HIERARCH <key path> = <value> / <comment>`.
        // The `=` sits past column 9, so the generic value-indicator check below
        // can't see it; without this branch every HIERARCH card collapses to a
        // single valueless card keyed "HIERARCH".
        if raw.hasPrefix("HIERARCH ") {
            return parseHierarchCard(raw)
        }
        let keyword = String(raw.prefix(8)).trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return nil }
        // Reserved structural keywords have no value
        if ["COMMENT", "HISTORY"].contains(keyword) {
            let rest = String(raw.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            return Card(keyword: keyword, value: nil, comment: rest.isEmpty ? nil : rest)
        }
        // Value indicator is column 9-10 = "= "
        guard raw.count >= 10, raw[raw.index(raw.startIndex, offsetBy: 8)] == "=" else {
            return Card(keyword: keyword, value: nil, comment: nil)
        }
        let body = String(raw.dropFirst(10))
        let (value, comment) = parseValueAndComment(body)
        return Card(keyword: keyword, value: value, comment: comment)
    }

    /// Parse a `HIERARCH ` card. The keyword is the (space-separated) key path
    /// between the prefix and the first `=`; the value/comment follow as usual.
    /// The key path is kept verbatim (no "HIERARCH " prefix) for lookup + round-trip.
    private static func parseHierarchCard(_ raw: String) -> Card {
        let afterPrefix = raw.dropFirst("HIERARCH ".count)
        guard let eq = afterPrefix.firstIndex(of: "=") else {
            let key = afterPrefix.trimmingCharacters(in: .whitespaces)
            return Card(keyword: key.isEmpty ? "HIERARCH" : key, value: nil, comment: nil)
        }
        let key = afterPrefix[..<eq].trimmingCharacters(in: .whitespaces)
        let body = String(afterPrefix[afterPrefix.index(after: eq)...])
        let (value, comment) = parseValueAndComment(body)
        return Card(keyword: key.isEmpty ? "HIERARCH" : key, value: value, comment: comment)
    }

    private static func parseValueAndComment(_ s: String) -> (Value?, String?) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("'") {
            // string value, single-quote delimited; doubled quote escapes
            var out = ""
            var i = trimmed.index(after: trimmed.startIndex)
            while i < trimmed.endIndex {
                let c = trimmed[i]
                if c == "'" {
                    let next = trimmed.index(after: i)
                    if next < trimmed.endIndex, trimmed[next] == "'" {
                        out.append("'")
                        i = trimmed.index(after: next)
                        continue
                    }
                    // end of string
                    let remainder = String(trimmed[trimmed.index(after: i)...])
                    let comment = extractComment(remainder)
                    return (.string(out.trimmingCharacters(in: .whitespaces)), comment)
                }
                out.append(c)
                i = trimmed.index(after: i)
            }
            return (.string(out.trimmingCharacters(in: .whitespaces)), nil)
        }
        // non-string: split at first '/'
        if let slash = trimmed.firstIndex(of: "/") {
            let valuePart = String(trimmed[..<slash]).trimmingCharacters(in: .whitespaces)
            let commentPart = String(trimmed[trimmed.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
            return (parseScalar(valuePart), commentPart.isEmpty ? nil : commentPart)
        }
        return (parseScalar(trimmed), nil)
    }

    private static func extractComment(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func parseScalar(_ s: String) -> Value? {
        if s == "T" { return .bool(true) }
        if s == "F" { return .bool(false) }
        if let i = Int(s) { return .integer(i) }
        if let d = Double(s.replacingOccurrences(of: "D", with: "E")) { return .float(d) }
        return nil
    }
}
