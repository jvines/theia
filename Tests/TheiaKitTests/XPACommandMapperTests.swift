import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class XPACommandMapperTests: XCTestCase {
    private func failure<T>(_ result: Result<T, XPARequestError>) -> String? {
        if case .failure(let error) = result { return error.message }
        return nil
    }

    func testGetUsesDocumentSnapshotAndDS9Names() {
        let snapshot = XPADocumentSnapshot(id: 4, path: "/data/star.fits",
                                           stretch: .power, colorMap: .gray,
                                           regions: [])
        XCTAssertEqual(XPACommandMapper.get(command: "version", document: nil),
                       .success("Theia \(AppVersion.string)"))
        XCTAssertEqual(XPACommandMapper.get(command: "frame", document: snapshot), .success("5"))
        XCTAssertEqual(XPACommandMapper.get(command: "file", document: snapshot), .success("/data/star.fits"))
        XCTAssertEqual(XPACommandMapper.get(command: "scale", document: snapshot), .success("pow"))
        XCTAssertEqual(XPACommandMapper.get(command: "cmap", document: snapshot), .success("gray"))
        XCTAssertEqual(XPACommandMapper.get(command: "regions", document: snapshot), .success(""))
        XCTAssertNotNil(failure(XPACommandMapper.get(command: "zoom", document: snapshot)))
        XCTAssertEqual(XPACommandMapper.get(command: "frame", document: nil), .success("0"))
        XCTAssertEqual(failure(XPACommandMapper.get(command: "file", document: nil)), "no image is open")
    }

    func testZscaleGetAnswersDS9sParameters() {
        let snapshot = XPADocumentSnapshot(id: 0, path: "/data/star.fits", stretch: .linear,
                                           colorMap: .gray, regions: [], zscaleContrast: 0.4)
        XCTAssertEqual(XPACommandMapper.get(command: "zscale", document: snapshot), .success("0.4"))
        XCTAssertEqual(XPACommandMapper.get(command: "zscale", params: "contrast", document: snapshot),
                       .success("0.4"))
        XCTAssertEqual(XPACommandMapper.get(command: "zscale", params: "sample", document: snapshot),
                       .success("600"))
        XCTAssertEqual(XPACommandMapper.get(command: "zscale", document: nil), .success("0.25"))
        XCTAssertNotNil(failure(XPACommandMapper.get(command: "zscale", params: "line", document: snapshot)))
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "zscale", params: "contrast 0.5", data: nil)))
        XCTAssertEqual(XPACommandMapper.set(command: "zscale", params: "", data: nil),
                       .success(.session([.applyScalePreset(.zscale)])))
    }

    func testScaleSetMapsPresetsAndRejectsUnsupportedModes() {
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "mode minmax", data: nil),
                       .success(.session([.applyScalePreset(.minMax)])))
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "mode 99.5", data: nil),
                       .success(.session([.applyScalePreset(.percentile(lower: 0.25, upper: 99.75))])))
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "histequal", data: nil),
                       .success(.session([.setStretch(.histogramEq)])))
        // DS9's own keywords.
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "histequ", data: nil),
                       .success(.session([.setStretch(.histogramEq)])))
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "sinh", data: nil),
                       .success(.session([.setStretch(.sinh)])))
        for (stretch, name) in [(ImageStretch.histogramEq, "histequ"), (.sinh, "sinh")] {
            let snapshot = XPADocumentSnapshot(id: 0, path: "/data/star.fits", stretch: stretch,
                                               colorMap: .gray, regions: [])
            XCTAssertEqual(XPACommandMapper.get(command: "scale", document: snapshot), .success(name))
        }
        XCTAssertEqual(XPACommandMapper.set(command: "scale", params: "limits 1 20", data: nil),
                       .success(.session([.setLevels(min: 1, max: 20)])))
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "scale", params: "mode bogus", data: nil)))
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "scale", params: "mode nan", data: nil)))
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "scale", params: "limits 1", data: nil)))
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "scale", params: "limits 1e40 20", data: nil)))
        XCTAssertTrue(failure(XPACommandMapper.set(command: "scale", params: "cubic", data: nil))?
            .contains("histequ") == true)
    }

    func testColormapNamesAreMatplotlibsCaseInsensitivelyWithDS9Aliases() {
        for (name, map) in [("hot", ColorMap.hot), ("HOT", .hot), ("Cool", .cool),
                            ("gist_heat", .gistHeat), ("Gist_Heat", .gistHeat),
                            ("afmhot", .afmhot), ("cubehelix", .cubehelix), ("inferno", .inferno),
                            ("hsv", .hsv), ("rainbow", .rainbow), ("Gray", .gray),
                            ("invertedgray", .invertedGray), ("invertedGray", .invertedGray),
                            ("Viridis", .viridis),
                            // DS9 names with a matplotlib counterpart.
                            ("grey", .gray), ("heat", .hot), ("bb", .afmhot), ("gray_r", .invertedGray)] {
            XCTAssertEqual(XPACommandMapper.set(command: "cmap", params: name, data: nil),
                           .success(.session([.setColormap(map)])), name)
        }
        // DS9's own tables are not offered.
        let message = failure(XPACommandMapper.set(command: "cmap", params: "sls", data: nil))
        XCTAssertEqual(message, "unknown colour map 'sls'; valid: "
            + XPACommandMapper.colorMapNames.joined(separator: " ")
            + " (DS9's grey, heat and bb give gray, hot and afmhot)")
        XCTAssertTrue(XPACommandMapper.colorMapNames.contains("gist_heat"))
        XCTAssertTrue(XPACommandMapper.colorMapNames.contains("invertedgray"))
    }

    func testFileRegionsColormapAndQuitMapWithoutPlatformCode() {
        XCTAssertEqual(XPACommandMapper.set(command: "file", params: "", data: Data("/tmp/a.fits".utf8)),
                       .success(.loadFile("/tmp/a.fits", newFrame: false)))
        // DS9 loads into the current frame; "new" asks for another frame.
        XCTAssertEqual(XPACommandMapper.set(command: "file", params: "/tmp/b.fits", data: nil),
                       .success(.loadFile("/tmp/b.fits", newFrame: false)))
        XCTAssertEqual(XPACommandMapper.set(command: "fits", params: "new /tmp/b.fits", data: nil),
                       .success(.loadFile("/tmp/b.fits", newFrame: true)))
        XCTAssertEqual(XPACommandMapper.set(command: "file", params: "new", data: Data("/tmp/c.fits".utf8)),
                       .success(.loadFile("/tmp/c.fits", newFrame: true)))
        XCTAssertEqual(XPACommandMapper.set(command: "file", params: "newer.fits", data: nil),
                       .success(.loadFile("newer.fits", newFrame: false)))
        // `xpaset ds9 fits < image.fits` sends the image itself.
        let image = Data("SIMPLE  =                    T".utf8) + Data(repeating: 32, count: 50)
        XCTAssertEqual(XPACommandMapper.set(command: "fits", params: "", data: image),
                       .success(.loadData(image, newFrame: false)))
        XCTAssertEqual(XPACommandMapper.set(command: "fits", params: "new", data: image),
                       .success(.loadData(image, newFrame: true)))
        // A file name in the parameters wins over whatever stdin carried.
        XCTAssertEqual(XPACommandMapper.set(command: "file", params: "/tmp/d.fits", data: image),
                       .success(.loadFile("/tmp/d.fits", newFrame: false)))
        XCTAssertEqual(XPACommandMapper.set(command: "regions", params: "", data: Data("image\n".utf8)),
                       .success(.session([.replaceRegions([])])))
        XCTAssertEqual(XPACommandMapper.set(command: "quit", params: "", data: nil), .success(.quit))
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "file", params: "", data: nil)))
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "zoom", params: "2", data: nil)))
        XCTAssertEqual(failure(XPACommandMapper.set(command: "regions", params: "nonsense", data: nil)),
                       "regions: cannot read 'unknown shape nonsense in line: nonsense'")
    }

    func testRegionsCommandAddsAndDeleteClearsLikeDS9() throws {
        let circle = try XCTUnwrap(RegionFile.parse("circle(100,100,20)").first)
        let box = try XCTUnwrap(RegionFile.parse("box(5,5,4,4,0)").first)
        for params in ["command {circle 100 100 20}", "command \"circle(100,100,20)\"",
                       "command 'circle 100 100 20'", "command circle 100 100 20"] {
            XCTAssertEqual(XPACommandMapper.set(command: "regions", params: params, data: nil),
                           .success(.session([.addRegion(circle)])), params)
        }
        XCTAssertEqual(XPACommandMapper.set(command: "regions",
                                            params: "command {circle 100 100 20; box 5 5 4 4 0}", data: nil),
                       .success(.session([.addRegion(circle), .addRegion(box)])))
        for params in ["delete", "delete all", "deleteall", "DELETE"] {
            XCTAssertEqual(XPACommandMapper.set(command: "regions", params: params, data: nil),
                           .success(.session([.clearRegions])), params)
        }
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "regions", params: "delete select", data: nil)))
        XCTAssertNotNil(failure(XPACommandMapper.set(command: "regions", params: "command {}", data: nil)))
        // Piped region text in DS9's one-line form.
        XCTAssertEqual(XPACommandMapper.set(command: "regions", params: "",
                                            data: Data("image; circle(100,100,20)".utf8)),
                       .success(.session([.replaceRegions([circle])])))
    }
}

final class PipedFITSTests: XCTestCase {
    @MainActor func testEachPipedImageGetsItsOwnStdinURL() async throws {
        let first = PipedFITS.nextURL()
        let second = PipedFITS.nextURL()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(PipedFITS.isPiped(first))
        XCTAssertFalse(first.isFileURL)
        XCTAssertEqual(first.lastPathComponent, "stdin")
        XCTAssertEqual(PipedFITS.displayPath(for: first), "stdin")
        XCTAssertEqual(PipedFITS.displayPath(for: URL(fileURLWithPath: "/data/a.fits")), "/data/a.fits")
        XCTAssertFalse(PipedFITS.isPiped(URL(fileURLWithPath: "/data/a.fits")))
    }

    @MainActor func testWorkspaceDoesNotRememberPipedImagesAsRecent() async throws {
        let workspace = Workspace()
        let url = PipedFITS.nextURL()
        let image = Data("SIMPLE  =                    T".utf8)
        XCTAssertTrue(PipedFITS.isFITS(image))
        XCTAssertFalse(PipedFITS.isFITS(Data("/tmp/a.fits".utf8)))
        var header = [
            "SIMPLE  =                    T", "BITPIX  =                    8",
            "NAXIS   =                    2", "NAXIS1  =                    2",
            "NAXIS2  =                    2", "END",
        ].map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        header = header.padding(toLength: 2880, withPad: " ", startingAt: 0)
        let data = Data(header.utf8) + Data([1, 2, 3, 4]) + Data(repeating: 0, count: 2876)
        let opened = try workspace.open(url: url) { url in
            DocumentSession(url: url, file: try FITSFile(data: data))
        }
        XCTAssertEqual(opened.effects, [.documentOpened(opened.documentID)])
    }
}
