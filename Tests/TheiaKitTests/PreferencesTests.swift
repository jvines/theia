import XCTest
import FITSCore
@testable import TheiaKit

final class PreferencesTests: XCTestCase {
    func testTypedKeysKeepExistingNamesAndSafeDefaults() {
        XCTAssertEqual(PreferenceKeys.DefaultStretch.name, "pref.defaultStretch")
        XCTAssertEqual(PreferenceKeys.DefaultColorMap.name, "pref.defaultColorMap")
        XCTAssertEqual(PreferenceKeys.ZScaleContrast.name, "pref.zscaleContrast")
        XCTAssertEqual(PreferenceKeys.PixelTableSize.name, "pref.pixelTableSize")
        XCTAssertEqual(PreferenceKeys.RegionColor.name, "pref.regionColor")
        XCTAssertEqual(PreferenceKeys.ReadoutFrame.name, "readoutFrame")
        XCTAssertEqual(PreferenceKeys.HasSeenOnboarding.name, "hasSeenOnboarding")

        XCTAssertEqual(PreferenceKeys.ZScaleContrast.defaultValue, 0.25)
        XCTAssertEqual(PreferenceKeys.PixelTableSize.defaultValue, 7)
        XCTAssertEqual(PreferenceKeys.RegionColor.defaultValue, "green")
        XCTAssertEqual(PreferenceKeys.RegionColor.normalize("violet"), "green")
        XCTAssertEqual(PreferenceKeys.RegionColor.normalize(" RED "), "red")
        XCTAssertEqual(PreferenceKeys.PixelTableSize.normalize(8), 7)
        XCTAssertEqual(PreferenceKeys.ZScaleContrast.normalize(.nan), 0.25)
    }

    func testZScaleUsesCurrentContrastForInitialAndSubsequentDisplays() async {
        await MainActor.run {
            let pixels = (0..<590).map { Float(99 + ($0 % 300)) / 100 }
                + Array(repeating: Float(100_000), count: 10)
            let image = FITSImage.fromFloat32(pixels: pixels, width: 30, height: 20)
            let expectedNarrow = image.defaultRange(contrast: 1)!
            let expectedWide = image.defaultRange(contrast: 0.25)!
            XCTAssertNotEqual(expectedNarrow.z2, expectedWide.z2)

            var contrast = 1.0
            let view = ImageViewState(image: image, zscaleContrast: { contrast })
            XCTAssertEqual(view.vmax, Float(expectedNarrow.z2))

            contrast = 0.25
            view.display(image, revision: 1)
            XCTAssertEqual(view.vmax, Float(expectedWide.z2))
            XCTAssertEqual(DocumentSession.recommendedLevels(for: image, contrast: contrast).vmax,
                           Float(expectedWide.z2))
        }
    }

    func testSessionZScaleCommandReadsLatestContrast() async throws {
        try await MainActor.run {
            let pixels = (0..<590).map { UInt8(99 + $0 % 3) }
                + Array(repeating: UInt8(255), count: 10)
            let cards = [
                "SIMPLE  =                    T", "BITPIX  =                    8",
                "NAXIS   =                    2", "NAXIS1  =                   30",
                "NAXIS2  =                   20", "END"
            ]
            var data = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().utf8)
            data.append(Data(repeating: 32, count: 2880 - data.count))
            data.append(contentsOf: pixels)
            data.append(Data(repeating: 0, count: 2880 - pixels.count))

            var contrast = 1.0
            let session = DocumentSession(url: URL(fileURLWithPath: "/tmp/preferences-test.fits"),
                                          file: try FITSFile(data: data),
                                          zscaleContrast: { contrast })
            let image = try XCTUnwrap(session.displayed)
            let narrow = try XCTUnwrap(image.defaultRange(contrast: 1))
            let wide = try XCTUnwrap(image.defaultRange(contrast: 0.25))
            XCTAssertNotEqual(narrow.z2, wide.z2)
            XCTAssertEqual(session.view.vmax, Float(narrow.z2))

            contrast = 0.25
            XCTAssertNil(session.perform(.applyScalePreset(.zscale), origin: .user).failure)
            XCTAssertEqual(session.view.vmax, Float(wide.z2))
        }
    }
}
