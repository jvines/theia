import Foundation

public enum FITSError: Error {
    case truncated
    case invalidHeader(String)
    case unsupportedBitpix(Int)
}

public struct FITSFile: Sendable {
    public let hdus: [FITSHDU]

    /// Index of the first HDU that holds an image (2D or 3D cube). Skips empty
    /// primary stubs (NAXIS=0) and table extensions.
    public var firstImageHDUIndex: Int? {
        hdus.firstIndex(where: { $0.isImage && $0.naxis >= 2 })
    }

    public init(data: Data) throws {
        var cursor = 0
        var hdus: [FITSHDU] = []
        // Hard upper bound on HDU count — typical files have ≤ 100; anything past
        // a few thousand is almost certainly malformed or a denial-of-service ploy.
        let maxHDUs = 4096
        while cursor < data.count {
            guard let (header, headerEnd) = try FITSHeader.parse(in: data, at: cursor) else {
                break
            }
            let dataStart = headerEnd
            guard let dataBytes = header.dataLengthBytes() else {
                throw FITSError.invalidHeader("invalid or overflowing dimensions")
            }
            // FITS data records are padded to multiples of 2880 bytes. Compute via
            // overflow-checked arithmetic to defend against a header that slipped
            // through with near-Int.max data sizes.
            let padded: Int = {
                let add = dataBytes.addingReportingOverflow(2879)
                if add.overflow { return Int.max }
                return (add.partialValue / 2880) * 2880
            }()
            let endResult = dataStart.addingReportingOverflow(padded)
            guard !endResult.overflow else {
                throw FITSError.invalidHeader("data block end overflows")
            }
            let dataEnd = endResult.partialValue
            guard dataEnd <= data.count else { throw FITSError.truncated }
            let sliceEndResult = dataStart.addingReportingOverflow(dataBytes)
            guard !sliceEndResult.overflow, sliceEndResult.partialValue <= data.count else {
                throw FITSError.truncated
            }
            // Slice via subscript (not `subdata`) so we keep viewing the
            // original (possibly mmap-backed) buffer instead of allocating a
            // copy. The resulting Data uses non-zero startIndex; readers must
            // index off `startIndex`, which `FITSImage.rawValue` / the
            // physicalValues fast path already do.
            let slice = data[dataStart..<sliceEndResult.partialValue]
            hdus.append(FITSHDU(header: header, data: slice))
            cursor = dataEnd
            guard hdus.count <= maxHDUs else {
                throw FITSError.invalidHeader("too many HDUs (>\(maxHDUs))")
            }
        }
        guard !hdus.isEmpty else { throw FITSError.invalidHeader("No HDUs found") }

        // Tile-compressed images (the `.fz` convention) are stored as BINTABLE
        // extensions with ZIMAGE=T. The pure-Swift reader can't decode them, so
        // hand each one to CFITSIO and swap in a synthesized uncompressed image
        // HDU. Everything downstream (FITSImage, WCS, cubes) then works unchanged.
        if hdus.contains(where: { $0.isCompressedImage }) {
            hdus = hdus.enumerated().map { idx, hdu in
                guard hdu.isCompressedImage else { return hdu }
                do {
                    let native = try CFITSIOLibrary.decompressNativeImage(fileData: data, hduIndex1Based: idx + 1)
                    let header = FITSHDU.synthesizedImageHeader(from: hdu.header, bitpix: native.bitpix, axes: native.axes)
                    return FITSHDU(header: header, data: native.bigEndianData)
                } catch {
                    // Decode failed — leave the original HDU so the file still opens
                    // (it'll show as a table rather than crashing the whole load).
                    return hdu
                }
            }
        }
        self.hdus = hdus
    }
}

public struct FITSHDU: Sendable {
    public let header: FITSHeader
    public let data: Data

    public var name: String? { header["EXTNAME"]?.stringValue }

    public var bitpix: Int { header["BITPIX"]?.intValue ?? 0 }
    public var naxis: Int { header["NAXIS"]?.intValue ?? 0 }

    /// `XTENSION` value, trimmed. `nil` for the primary HDU.
    public var xtension: String? {
        header["XTENSION"]?.stringValue?.trimmingCharacters(in: .whitespaces)
    }

    /// True for primary arrays with image data and for `IMAGE` extensions.
    public var isImage: Bool {
        if let x = xtension { return x == "IMAGE" }
        return naxis >= 2
    }

    /// True for `BINTABLE` and `TABLE` extensions.
    public var isTable: Bool {
        guard let x = xtension else { return false }
        return x == "BINTABLE" || x == "TABLE"
    }

    /// True for a tile-compressed image: a BINTABLE carrying the `ZIMAGE=T`
    /// convention (`.fz` files). These are decompressed at parse time.
    public var isCompressedImage: Bool {
        guard xtension == "BINTABLE" else { return false }
        if case .bool(true) = header["ZIMAGE"] { return true }
        return false
    }

    /// Builds the uncompressed-equivalent image header for a tile-compressed HDU:
    /// real BITPIX/NAXIS/NAXISn (from the decode), science + WCS keywords carried
    /// over, table and compression machinery dropped. CFITSIO has already applied
    /// BSCALE/BZERO, so those are dropped to avoid double-scaling.
    static func synthesizedImageHeader(from original: FITSHeader, bitpix: Int, axes: [Int]) -> FITSHeader {
        let dropExact: Set<String> = [
            "XTENSION", "BITPIX", "NAXIS", "PCOUNT", "GCOUNT", "TFIELDS", "THEAP",
            "BSCALE", "BZERO", "BLANK",
            "ZIMAGE", "ZCMPTYPE", "ZBITPIX", "ZNAXIS", "ZSIMPLE", "ZEXTEND",
            "ZTENSION", "ZPCOUNT", "ZGCOUNT", "ZHECKSUM", "ZDATASUM",
            "ZQUANTIZ", "ZDITHER0", "ZBLANK", "ZMASKCMP",
        ]
        // Indexed keyword families that are table/compression-only.
        let dropIndexedPrefixes = [
            "NAXIS", "TFORM", "TTYPE", "TUNIT", "TSCAL", "TZERO", "TDISP", "TNULL", "TDIM",
            "ZNAXIS", "ZTILE", "ZNAME", "ZVAL",
        ]
        func isDropped(_ k: String) -> Bool {
            if dropExact.contains(k) { return true }
            for prefix in dropIndexedPrefixes where k.hasPrefix(prefix) {
                let suffix = k.dropFirst(prefix.count)
                if !suffix.isEmpty, Int(suffix) != nil { return true }
            }
            return false
        }
        var cards: [FITSHeader.Card] = [
            .init(keyword: "XTENSION", value: .string("IMAGE"), comment: "decompressed from tile-compressed FITS"),
            .init(keyword: "BITPIX", value: .integer(bitpix), comment: nil),
            .init(keyword: "NAXIS", value: .integer(axes.count), comment: nil),
        ]
        for (i, dim) in axes.enumerated() {
            cards.append(.init(keyword: "NAXIS\(i + 1)", value: .integer(dim), comment: nil))
        }
        for card in original.cards where !isDropped(card.keyword) {
            cards.append(card)
        }
        return FITSHeader(cards: cards)
    }

    public var axes: [Int] {
        guard naxis > 0 else { return [] }
        return (1...naxis).compactMap { header["NAXIS\($0)"]?.intValue }
    }

    public var kindLabel: String {
        if isTable { return xtension?.lowercased() ?? "table" }
        if naxis == 0 { return "primary (no data)" }
        if naxis == 1 { return "1D" }
        if naxis == 2 { return "image" }
        return "\(naxis)D cube"
    }

    /// Number of planes along the third axis (1 for NAXIS≤2).
    public var planeCount: Int {
        naxis >= 3 ? (header["NAXIS3"]?.intValue ?? 1) : 1
    }

    public var shapeDescription: String {
        if axes.isEmpty { return "no data" }
        return axes.map(String.init).joined(separator: " × ")
    }

    public var bitpixLabel: String {
        switch bitpix {
        case 8: return "uint8"
        case 16: return "int16"
        case 32: return "int32"
        case 64: return "int64"
        case -32: return "float32"
        case -64: return "float64"
        default: return "BITPIX \(bitpix)"
        }
    }
}
