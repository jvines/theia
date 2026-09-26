import Foundation
import Observation
import FITSCore

/// An image operation's result, kept separate from the source HDU and its cube.
public struct DerivedImage: Equatable {
    public let id: UUID
    public let image: FITSImage
    public let wcs: WCS?
    public let label: String

    public init(image: FITSImage, wcs: WCS?, label: String, id: UUID = UUID()) {
        self.id = id
        self.image = image
        self.wcs = wcs
        self.label = label
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Facts that are stable for the lifetime of an open FITS file. Parsing WCS
/// variants here keeps menu enablement and ordinary view updates cheap.
public struct HDUFacts {
    public let isDisplayableImage: Bool
    public let shape: SIMD2<Int>?
    public let planeCount: Int
    public let wcsVariants: [String]
    public let wcsVariantLabels: [String: String]
    private let wcsByVariant: [String: WCS]

    init(hdu: FITSHDU) {
        let axes = hdu.axes
        isDisplayableImage = hdu.isImage && axes.count >= 2 && axes.allSatisfy { $0 > 0 }
        shape = isDisplayableImage ? SIMD2(axes[0], axes[1]) : nil
        planeCount = axes.dropFirst(2).reduce(1) { count, axis in
            let result = count.multipliedReportingOverflow(by: axis)
            return result.overflow ? 0 : result.partialValue
        }
        wcsVariants = WCS.availableVariants(in: hdu.header)
        wcsVariantLabels = Dictionary(uniqueKeysWithValues: wcsVariants.compactMap { variant in
            hdu.header["WCSNAME\(variant)"]?.stringValue.map { (variant, $0) }
        })
        wcsByVariant = Dictionary(uniqueKeysWithValues: wcsVariants.compactMap { variant in
            WCS(header: hdu.header, variant: variant).map { (variant, $0) }
        })
    }

    public func wcs(variant: String) -> WCS? { wcsByVariant[variant] }
}

/// Source, selection, and displayed-image identity for one open document.
/// Expensive decoded planes are cached by source HDU and plane. A derived image
/// has precedence over that source until an HDU or plane is selected.
@MainActor @Observable public final class DocumentSession {
    public let url: URL
    public let file: FITSFile
    public let facts: [HDUFacts]
    public private(set) var hdu: Int
    public private(set) var plane: Int = 0
    public private(set) var wcsVariant: String = ""
    public private(set) var derived: DerivedImage?
    public private(set) var imageRevision: Int = 0

    private struct ImageKey: Hashable {
        let hdu: Int
        let plane: Int
    }
    @ObservationIgnored private var imageCache: [ImageKey: FITSImage] = [:]
    @ObservationIgnored internal private(set) var decodedImageCount = 0

    public init(url: URL, file: FITSFile) {
        self.url = url
        self.file = file
        self.facts = file.hdus.map(HDUFacts.init)
        self.hdu = file.firstImageHDUIndex ?? 0
        self.wcsVariant = facts[hdu].wcsVariants.first ?? ""
    }

    public var displayed: FITSImage? {
        if let derived { return derived.image }
        guard facts.indices.contains(hdu), facts[hdu].isDisplayableImage else { return nil }
        let key = ImageKey(hdu: hdu, plane: plane)
        if let cached = imageCache[key] { return cached }
        guard let image = try? FITSImage(hdu: file.hdus[hdu], plane: plane) else { return nil }
        imageCache[key] = image
        decodedImageCount += 1
        return image
    }

    public var displayedWCS: WCS? {
        if let derived { return derived.wcs }
        guard facts.indices.contains(hdu), displayed != nil else { return nil }
        return facts[hdu].wcs(variant: wcsVariant)
    }

    /// The next image HDU of the same width and height, wrapping at the end.
    public var blinkPartner: Int? {
        guard facts.indices.contains(hdu), let shape = facts[hdu].shape, facts.count > 1 else { return nil }
        for step in 1..<facts.count {
            let candidate = (hdu + step) % facts.count
            if facts[candidate].shape == shape { return candidate }
        }
        return nil
    }

    public func selectHDU(_ index: Int) {
        guard facts.indices.contains(index), index != hdu else { return }
        hdu = index
        plane = 0
        derived = nil
        wcsVariant = facts[index].wcsVariants.first ?? ""
        imageRevision &+= 1
    }

    public func selectPlane(_ index: Int) {
        guard facts.indices.contains(hdu), facts[hdu].isDisplayableImage,
              index >= 0, index < facts[hdu].planeCount,
              index != plane || derived != nil else { return }
        plane = index
        derived = nil
        imageRevision &+= 1
    }

    public func selectWCSVariant(_ variant: String) {
        guard facts[hdu].wcsVariants.contains(variant), variant != wcsVariant else { return }
        wcsVariant = variant
    }

    public func setDerived(_ image: DerivedImage?) {
        guard derived != image else { return }
        derived = image
        imageRevision &+= 1
    }
}
