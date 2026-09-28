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

    private var sampleDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("resources/samples")
    }
}
