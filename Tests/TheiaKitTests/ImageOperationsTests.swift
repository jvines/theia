import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class ImageOperationsTests: XCTestCase {
    func testBinAveragesNonNaNSamplesAndPreservesSkyAtBlockCenter() throws {
        let image = FITSImage.fromFloat32(pixels: [
            1, 3, 5, 7,
            9, .nan, 13, 15,
            17, 19, 21, 23,
            25, 27, 29, 31,
        ], width: 4, height: 4)
        let wcs = try makeWCS()
        let result = try XCTUnwrap(ImageOperations.bin(image, wcs: wcs, factor: 2))
        XCTAssertEqual(result.image.width, 2)
        XCTAssertEqual(result.image.height, 2)
        XCTAssertEqual(result.image.physicalValue(x: 0, y: 0), 13.0 / 3, accuracy: 1e-5)
        XCTAssertEqual(result.image.physicalValue(x: 1, y: 0), 10, accuracy: 1e-5)
        let originalSky = try XCTUnwrap(wcs.pixelToSky(imageX: 0.5, imageY: 0.5))
        let newSky = try XCTUnwrap(result.wcs?.pixelToSky(imageX: 0, imageY: 0))
        XCTAssertEqual(newSky.ra, originalSky.ra, accuracy: 1e-9)
        XCTAssertEqual(newSky.dec, originalSky.dec, accuracy: 1e-9)
        XCTAssertNil(ImageOperations.bin(image, wcs: wcs, factor: 5))
    }

    func testCropCopiesSelectedPixelsAndOffsetsWCS() throws {
        let image = FITSImage.fromFloat32(pixels: [
            1, 2, 3, 4,
            5, 6, 7, 8,
            9, 10, 11, 12,
            13, 14, 15, 16,
        ], width: 4, height: 4)
        let wcs = try makeWCS()
        let result = try XCTUnwrap(ImageOperations.crop(image, wcs: wcs,
                                                        originX: 1, originY: 1,
                                                        width: 2, height: 2))
        XCTAssertEqual(result.image.width, 2)
        XCTAssertEqual(result.image.height, 2)
        XCTAssertEqual(result.image.physicalValue(x: 0, y: 0), 6)
        XCTAssertEqual(result.image.physicalValue(x: 1, y: 1), 11)
        let originalSky = try XCTUnwrap(wcs.pixelToSky(imageX: 2, imageY: 2))
        let newSky = try XCTUnwrap(result.wcs?.pixelToSky(imageX: 1, imageY: 1))
        XCTAssertEqual(newSky.ra, originalSky.ra, accuracy: 1e-9)
        XCTAssertEqual(newSky.dec, originalSky.dec, accuracy: 1e-9)
        XCTAssertNil(ImageOperations.crop(image, wcs: wcs, originX: 3, originY: 3,
                                          width: 2, height: 2))
    }

    func testStackKeepsReferenceWCSAndRejectsUnalignedDimensions() throws {
        let first = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let second = FITSImage.fromFloat32(pixels: [5, 6, 7, 8], width: 2, height: 2)
        let wcs = try makeWCS()
        let stack = try XCTUnwrap(ImageOperations.stack([first, second],
                                                         referenceWCS: wcs, mode: .mean))
        XCTAssertEqual(stack.image.physicalValue(x: 0, y: 0), 3)
        XCTAssertEqual(stack.image.physicalValue(x: 1, y: 1), 6)
        XCTAssertEqual(stack.wcs?.crpix.x, wcs.crpix.x)
        XCTAssertEqual(stack.wcs?.cd11, wcs.cd11)
        XCTAssertNil(ImageOperations.stack([first], referenceWCS: wcs, mode: .sum))
        XCTAssertNil(ImageOperations.stack([first, FITSImage.fromFloat32(pixels: [1], width: 1, height: 1)],
                                           referenceWCS: wcs, mode: .median))
    }

    func testBinRejectsUnrepresentableWCSRatherThanDroppingIt() throws {
        let image = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let wcs = try makeOverflowWCS()
        XCTAssertNil(wcs.binned(by: 2))
        XCTAssertNil(ImageOperations.bin(image, wcs: wcs, factor: 2))
    }

    private func makeWCS() throws -> WCS {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'", "CTYPE2  = 'DEC--TAN'",
            "CRPIX1  =                  1.0", "CRPIX2  =                  1.0",
            "CRVAL1  =                180.0", "CRVAL2  =                  0.0",
            "CDELT1  =        -0.0002777778", "CDELT2  =         0.0002777778", "END",
        ]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        return try XCTUnwrap(WCS(header: FITSFile(data: Data(text.utf8)).hdus[0].header))
    }

    private func makeOverflowWCS() throws -> WCS {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN-SIP'", "CTYPE2  = 'DEC--TAN-SIP'",
            "CRPIX1  =                  1.0", "CRPIX2  =                  1.0",
            "CRVAL1  =                180.0", "CRVAL2  =                  0.0",
            "CDELT1  =        -0.0002777778", "CDELT2  =         0.0002777778",
            "A_ORDER =                    2", "A_2_0   =              1.0e308", "END",
        ]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        return try XCTUnwrap(WCS(header: FITSFile(data: Data(text.utf8)).hdus[0].header))
    }
}
