import XCTest
@testable import FITSCore

final class FixturesTests: XCTestCase {
    func testUInt8SimpleFixtureLoadsAndRoundTripsPixels() throws {
        let image = try loadImage(named: "uint8_simple")
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 16)
        // generator writes (x + y*16) % 256 in row-major
        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(image.physicalValue(x: 15, y: 0), 15)
        XCTAssertEqual(image.physicalValue(x: 0, y: 1), 16)
        XCTAssertEqual(image.physicalValue(x: 15, y: 15), Double(15 + 15 * 16))  // 255
    }

    func testFloat32BSCALEFixtureAppliesScaling() throws {
        let image = try loadImage(named: "float32_bscale")
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 32)
        XCTAssertEqual(image.bscale, 2.0)
        XCTAssertEqual(image.bzero, 10.0)
        // Peak of the Gaussian is the brightest physical value.
        let peak = image.physicalValue(x: 16, y: 16)
        let corner = image.physicalValue(x: 0, y: 0)
        XCTAssertGreaterThan(peak, corner)
        // peak raw ≈ 500, physical = 10 + 2 * 500 = 1010 (with tolerance for sampling).
        XCTAssertEqual(peak, 1010, accuracy: 20)
    }

    func testMultiHDUFixtureExposesPrimaryAndImageExtension() throws {
        let file = try loadFile(named: "multi_hdu")
        XCTAssertEqual(file.hdus.count, 2)
        let primary = file.hdus[0]
        let ext = file.hdus[1]
        XCTAssertEqual(primary.naxis, 0)
        XCTAssertEqual(ext.naxis, 2)
        XCTAssertEqual(ext.axes, [8, 8])
        XCTAssertEqual(ext.name, "SCI")

        let image = try FITSImage(hdu: ext)
        XCTAssertEqual(image.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(image.physicalValue(x: 7, y: 0), 7)
        XCTAssertEqual(image.physicalValue(x: 7, y: 7), 63)
    }

    // MARK: - Helpers

    private func loadFile(named name: String) throws -> FITSFile {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "fits",
            subdirectory: "Fixtures"
        ) else {
            throw XCTSkip("Fixture '\(name).fits' not found in test bundle")
        }
        return try FITSFile(data: Data(contentsOf: url))
    }

    private func loadImage(named name: String) throws -> FITSImage {
        let file = try loadFile(named: name)
        return try FITSImage(hdu: file.hdus[0])
    }
}
