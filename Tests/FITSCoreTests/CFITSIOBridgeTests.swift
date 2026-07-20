import XCTest
import Foundation
@testable import FITSCore

final class CFITSIOBridgeTests: XCTestCase {
    /// Proves the vendored CFITSIO C target links and is callable at runtime,
    /// and pins the vendored version so an accidental downgrade is caught.
    func testLinkedVersionIs464() {
        // ffvers encodes major + minor/100 + micro/10000 → 4.6.4 == 4.0604.
        let v = CFITSIOLibrary.version
        XCTAssertEqual(v, 4.0604, accuracy: 0.00005, "linked CFITSIO version \(v)")
    }

    // MARK: - Tile-compression round-trips

    /// Integer RICE is lossless — decompressed pixels must match the native
    /// reader exactly. Also proves dimensions and pixel ordering line up.
    func testRiceRoundTripIntegerExact() throws {
        try roundTrip(fixture: "uint8_simple", algorithm: "R", exact: true)
    }

    /// GZIP preserves float bit patterns — decompressed floats must match exactly.
    func testGzipRoundTripFloatExact() throws {
        try roundTrip(fixture: "float32_bscale", algorithm: "G", exact: true)
    }

    /// RICE on floats goes through CFITSIO's quantize + subtractive-dither path
    /// (the lossy, easy-to-get-wrong one). Not exact, but must stay within a
    /// small fraction of the data's dynamic range — i.e. not garbage.
    func testRiceRoundTripFloatWithinQuantizationTolerance() throws {
        try roundTrip(fixture: "float32_bscale", algorithm: "R", exact: false)
    }

    // MARK: - Helper

    private func roundTrip(fixture: String, algorithm: String, exact: Bool) throws {
        guard let url = Bundle.module.url(forResource: fixture, withExtension: "fits", subdirectory: "Fixtures") else {
            throw XCTSkip("Fixture '\(fixture).fits' not found")
        }
        // Native reference.
        let file = try FITSFile(data: Data(contentsOf: url))
        guard let idx = file.firstImageHDUIndex else { throw XCTSkip("no image HDU in \(fixture)") }
        let img = try FITSImage(hdu: file.hdus[idx])
        let native = img.physicalValues()

        // Compress with CFITSIO, then read back through the decode path.
        let tmp = NSTemporaryDirectory() + "rt_\(fixture)_\(algorithm)_\(UUID().uuidString).fz"
        try CFITSIOLibrary.writeCompressed(from: url.path, to: tmp, algorithm: algorithm)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let decoded = try CFITSIOLibrary.readPhysicalImage(path: tmp)

        XCTAssertEqual(decoded.width, img.width, "width")
        XCTAssertEqual(decoded.height, img.height, "height")
        XCTAssertEqual(decoded.pixels.count, native.count, "pixel count")

        if exact {
            for i in 0..<native.count {
                XCTAssertEqual(decoded.pixels[i], native[i], accuracy: 1e-9,
                               "pixel \(i): decoded \(decoded.pixels[i]) vs native \(native[i])")
            }
        } else {
            let lo = native.min() ?? 0
            let hi = native.max() ?? 1
            let tol = max(1e-6, 0.01 * (hi - lo))   // 1% of dynamic range
            for i in 0..<native.count {
                XCTAssert(decoded.pixels[i].isFinite, "pixel \(i) not finite")
                XCTAssertEqual(decoded.pixels[i], native[i], accuracy: tol,
                               "pixel \(i): decoded \(decoded.pixels[i]) vs native \(native[i]) (tol \(tol))")
            }
        }
    }
}
