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

    func testFilterAndUnaryPreserveDisplayedWCSAndChainPixels() throws {
        let wcs = try makeWCS()
        let image = FITSImage.fromFloat32(pixels: [1, 3, 5, 7], width: 2, height: 2)
        let filtered = try XCTUnwrap(ImageOperations.filter(image, wcs: wcs,
                                                             spec: .boxcar(size: 3)))
        XCTAssertEqual(filtered.image.physicalValue(x: 0, y: 0), 3)
        XCTAssertEqual(filtered.wcs?.crpix.x, wcs.crpix.x)
        XCTAssertEqual(filtered.label, "Boxcar 3×3")

        let squared = ImageOperations.unary(filtered.image, wcs: filtered.wcs, op: .square)
        XCTAssertEqual(squared.image.physicalValue(x: 0, y: 0), 9)
        XCTAssertEqual(squared.wcs?.crval.ra, wcs.crval.ra)
        XCTAssertEqual(squared.label, "Square")
        XCTAssertNil(ImageOperations.filter(image, wcs: wcs, spec: .gaussian(sigma: -.infinity)))
        XCTAssertNil(ImageOperations.filter(image, wcs: wcs, spec: .median(size: Int.max)))
        XCTAssertNil(ImageOperations.filter(image, wcs: wcs, spec: .boxcar(size: Int.max)))
        XCTAssertNil(ImageOperations.filter(image, wcs: wcs,
                                            spec: .gaussian(sigma: Double(Int.max) / 4)))
    }

    func testBinaryRejectsShapeMismatchAndKeepsTheActiveWCS() throws {
        let wcs = try makeWCS()
        let active = FITSImage.fromFloat32(pixels: [2, 4, .nan, 8], width: 2, height: 2)
        let other = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let result = try ImageOperations.binary(active, wcs: wcs, other: other,
                                                op: .difference, otherHDU: 3)
        XCTAssertEqual(result.image.physicalValue(x: 0, y: 0), 1)
        XCTAssertTrue(result.image.physicalValue(x: 0, y: 1).isNaN)
        XCTAssertEqual(result.wcs?.crpix.x, wcs.crpix.x)
        XCTAssertEqual(result.label, "Difference vs HDU 3")
        let mismatched = FITSImage.fromFloat32(pixels: [1], width: 1, height: 1)
        XCTAssertThrowsError(try ImageOperations.binary(active, wcs: wcs,
                                                         other: mismatched, op: .sum, otherHDU: 4))
    }

    func testBackgroundSubtractionPreservesWCSAndNaNs() throws {
        let wcs = try makeWCS()
        let image = FITSImage.fromFloat32(pixels: [10, 10, 12, .nan], width: 2, height: 2)
        let result = try XCTUnwrap(ImageOperations.subtractBackground(image, wcs: wcs))
        XCTAssertEqual(result.image.physicalValue(x: 0, y: 0), -2.0 / 3, accuracy: 1e-5)
        XCTAssertTrue(result.image.physicalValue(x: 1, y: 1).isNaN)
        XCTAssertEqual(result.wcs?.crpix.y, wcs.crpix.y)
        XCTAssertTrue(result.label.hasPrefix("BG sub ("))
    }

    func testReprojectUsesDisplayedWCSAndTargetGridWCS() throws {
        let wcs = try makeWCS()
        let image = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let result = try XCTUnwrap(ImageOperations.reproject(
            image, sourceWCS: wcs, targetWCS: wcs,
            targetWidth: 2, targetHeight: 2, targetHDU: 5
        ))
        XCTAssertEqual(result.image.physicalValue(x: 1, y: 1), 4, accuracy: 1e-5)
        XCTAssertEqual(result.wcs?.crval.ra, wcs.crval.ra)
        XCTAssertEqual(result.label, "Reprojected onto HDU 5")
        XCTAssertNil(ImageOperations.reproject(image, sourceWCS: wcs, targetWCS: wcs,
                                               targetWidth: 0, targetHeight: 2, targetHDU: 5))
    }

    func testRegionCropUsesImageFrameGeometryAndDisplayedWCS() throws {
        let image = FITSImage.fromFloat32(pixels: (0..<25).map(Float.init),
                                           width: 5, height: 5)
        let wcs = try makeWCS()
        let region = Region(
            shape: .box(center: .init(x: 3, y: 3),
                        width: .init(value: 3, unit: .pixel),
                        height: .init(value: 3, unit: .pixel), angle: 0),
            frame: .image
        )
        let result = try XCTUnwrap(ImageOperations.cropToRegion(image, wcs: wcs,
                                                                region: region))
        XCTAssertEqual(result.image.width, 3)
        XCTAssertEqual(result.image.height, 3)
        XCTAssertEqual(result.image.physicalValue(x: 0, y: 0), 6)
        XCTAssertEqual(result.image.physicalValue(x: 2, y: 2), 18)
        let originalSky = try XCTUnwrap(wcs.pixelToSky(imageX: 1, imageY: 1))
        let croppedSky = try XCTUnwrap(result.wcs?.pixelToSky(imageX: 0, imageY: 0))
        XCTAssertEqual(croppedSky.ra, originalSky.ra, accuracy: 1e-9)
        XCTAssertEqual(croppedSky.dec, originalSky.dec, accuracy: 1e-9)
    }

    func testCancellableBinAndRegionCropStopInsideLargePixelLoops() {
        enum Stop: Error { case requested }
        let image = FITSImage.fromFloat32(
            pixels: [Float](repeating: 1, count: 512 * 512), width: 512, height: 512
        )
        let region = Region(
            shape: .circle(center: .init(x: 256, y: 256),
                           radius: .init(value: 200, unit: .pixel)),
            frame: .image
        )
        func check() -> () throws -> Void {
            var calls = 0
            return {
                calls += 1
                if calls == 3 { throw Stop.requested }
            }
        }
        XCTAssertThrowsError(try ImageOperations.binCheckingCancellation(
            image, wcs: nil, factor: 2, checkCancellation: check()
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertThrowsError(try ImageOperations.cropToRegionCheckingCancellation(
            image, wcs: nil, region: region, checkCancellation: check()
        )) { XCTAssertTrue($0 is Stop) }
    }

    func testStackCanBeCancelledInsidePixelLoop() {
        enum Stop: Error { case requested }
        let image = FITSImage.fromFloat32(pixels: [Float](repeating: 1, count: 512 * 512),
                                          width: 512, height: 512)
        var checks = 0
        XCTAssertThrowsError(try ImageOperations.stackCheckingCancellation(
            [image, image], referenceWCS: nil, mode: .sum,
            checkCancellation: {
                checks += 1
                if checks == 3 { throw Stop.requested }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertGreaterThan(checks, 2)
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
