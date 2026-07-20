import XCTest
import Foundation
@testable import FITSCore

/// End-to-end: a tile-compressed (`.fz`) file opened through the normal
/// `FITSFile` → `FITSImage` path (the same path the app uses), proving the
/// CFITSIO decompression is wired in transparently.
final class CompressedImageTests: XCTestCase {

    func testCompressedFloatOpensAsImageWithMatchingPixels() throws {
        try roundTripThroughFITSFile(fixture: "float32_bscale", algorithm: "G", exact: true)
    }

    func testCompressedIntegerOpensAsImageWithExactPixels() throws {
        try roundTripThroughFITSFile(fixture: "uint8_simple", algorithm: "R", exact: true)
    }

    /// WCS and science keywords stored uncompressed in the tile-compressed header
    /// must survive into the synthesized image header.
    func testCompressedHeaderPreservesWCSKeywords() throws {
        guard let url = Bundle.module.url(forResource: "float32_bscale", withExtension: "fits", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture missing")
        }
        let original = try FITSFile(data: Data(contentsOf: url))
        let originalKeys = Set(original.hdus[original.firstImageHDUIndex!].header.cards.map(\.keyword))

        let tmp = NSTemporaryDirectory() + "wcs_\(UUID().uuidString).fz"
        try CFITSIOLibrary.writeCompressed(from: url.path, to: tmp, algorithm: "R")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let opened = try FITSFile(data: Data(contentsOf: URL(fileURLWithPath: tmp)))
        let idx = try XCTUnwrap(opened.firstImageHDUIndex, "compressed image not recognized as image HDU")
        let hdu = opened.hdus[idx]
        XCTAssertFalse(hdu.isCompressedImage, "should have been decompressed in place")
        XCTAssertTrue(hdu.isImage)

        // Any WCS/science keyword present in the original (and not structural) should carry over.
        let structural: Set<String> = ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "EXTEND", "BSCALE", "BZERO"]
        let carried = Set(hdu.header.cards.map(\.keyword))
        for key in originalKeys.subtracting(structural) where key != "END" {
            XCTAssertTrue(carried.contains(key), "keyword \(key) lost during decompression")
        }
    }

    /// Reads a committed, on-disk `.fz` fixture (RICE-compressed) end to end —
    /// proving we open real tile-compressed files, not just ones we compressed at
    /// runtime. Pixels are compared against the uncompressed source within RICE's
    /// float quantization tolerance.
    func testCommittedRiceFixtureOpensAndDecodes() throws {
        guard let fz = Bundle.module.url(forResource: "compressed_rice.fits", withExtension: "fz", subdirectory: "Fixtures"),
              let src = Bundle.module.url(forResource: "float32_bscale", withExtension: "fits", subdirectory: "Fixtures") else {
            throw XCTSkip("fixtures missing")
        }
        let nativeImg = try FITSImage(hdu: { let f = try FITSFile(data: Data(contentsOf: src)); return f.hdus[f.firstImageHDUIndex!] }())
        let native = nativeImg.physicalValues()

        let file = try FITSFile(data: Data(contentsOf: fz))
        let idx = try XCTUnwrap(file.firstImageHDUIndex, "committed .fz not exposed as image HDU")
        let img = try FITSImage(hdu: file.hdus[idx])
        XCTAssertEqual(img.width, nativeImg.width)
        XCTAssertEqual(img.height, nativeImg.height)

        let pixels = img.physicalValues()
        let lo = native.min() ?? 0, hi = native.max() ?? 1
        let tol = max(1e-6, 0.01 * (hi - lo))
        for i in 0..<pixels.count {
            XCTAssert(pixels[i].isFinite)
            XCTAssertEqual(pixels[i], native[i], accuracy: tol)
        }
    }

    // MARK: - Helper

    private func roundTripThroughFITSFile(fixture: String, algorithm: String, exact: Bool) throws {
        guard let url = Bundle.module.url(forResource: fixture, withExtension: "fits", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture '\(fixture)' missing")
        }
        let nativeFile = try FITSFile(data: Data(contentsOf: url))
        let nativeImg = try FITSImage(hdu: nativeFile.hdus[nativeFile.firstImageHDUIndex!])
        let nativePixels = nativeImg.physicalValues()

        let tmp = NSTemporaryDirectory() + "e2e_\(fixture)_\(UUID().uuidString).fz"
        try CFITSIOLibrary.writeCompressed(from: url.path, to: tmp, algorithm: algorithm)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let file = try FITSFile(data: Data(contentsOf: URL(fileURLWithPath: tmp)))
        let idx = try XCTUnwrap(file.firstImageHDUIndex, "compressed image not exposed as image HDU")
        let img = try FITSImage(hdu: file.hdus[idx])

        XCTAssertEqual(img.width, nativeImg.width)
        XCTAssertEqual(img.height, nativeImg.height)
        let pixels = img.physicalValues()
        XCTAssertEqual(pixels.count, nativePixels.count)
        if exact {
            for i in 0..<pixels.count {
                XCTAssertEqual(pixels[i], nativePixels[i], accuracy: 1e-5,
                               "pixel \(i): \(pixels[i]) vs \(nativePixels[i])")
            }
        }
    }
}
