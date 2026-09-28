import FITSCore
import Foundation
import TheiaKit
import XCTest

final class BundledSamplesTests: XCTestCase {
    func testDiscoveryShowsOnlySamplesPresentInTheInstalledDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-samples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(BundledSamples.available(in: directory).isEmpty)
        let source = sampleDirectory.appendingPathComponent("nicmos_mosaic.fits")
        try FileManager.default.copyItem(at: source,
                                         to: directory.appendingPathComponent("nicmos_mosaic.fits"))
        let available = BundledSamples.available(in: directory)
        XCTAssertEqual(available.map(\.title), ["Hubble NICMOS image"])
        XCTAssertEqual(available.map(\.url),
                       [directory.appendingPathComponent("nicmos_mosaic.fits")])
    }

    func testDistributedExamplesContainAnImageCubeAndTable() throws {
        let root = sampleDirectory
        let cases: [(String, (FITSFile) -> Bool)] = [
            ("nicmos_mosaic.fits", { $0.firstImageHDUIndex != nil }),
            ("wfpc2_cube.fits", { $0.hdus.contains { $0.isImage && $0.naxis == 3 } }),
            ("fos_bintable.fits", { $0.hdus.contains { $0.isTable } }),
        ]
        for (name, supportsFeature) in cases {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("Missing distributed FITS example: \(name)")
                continue
            }
            let file = try FITSFile(data: Data(contentsOf: url))
            XCTAssertTrue(supportsFeature(file), "Example does not exercise its feature: \(name)")
        }
    }

    func testTauCetiFerosExampleOpensAsAnEchelleCube() throws {
        let name = "feros_tau_ceti_20240730.fits"
        let url = sampleDirectory.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing FEROS example")
        let sample = try XCTUnwrap(BundledSamples.available(in: sampleDirectory)
            .first { $0.fileName == name })
        XCTAssertEqual(sample.title, "FEROS Tau Ceti echelle spectrum")

        let file = try FITSFile(data: Data(contentsOf: sample.url))
        let image = try XCTUnwrap(file.hdus.first { $0.isImage })
        XCTAssertEqual(image.axes, [4096, 25, 11])
        let wavelengths = try FITSImage(hdu: image, plane: 0)
        let flux = try FITSImage(hdu: image, plane: 1)
        XCTAssertEqual(wavelengths.physicalValue(x: 2000, y: 10), 5149.76332662499,
                       accuracy: 0.000001)
        XCTAssertEqual(flux.physicalValue(x: 2000, y: 10), 29788.49510487089,
                       accuracy: 0.000001)
    }

    private var sampleDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("resources/samples")
    }
}
