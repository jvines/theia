import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKPreferencesTests: XCTestCase {
    @MainActor func testXDGPreferencesPersistTypedDefaultsAndNormalizeValues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-preferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(platform: .linux, homeDirectory: root,
                             environment: ["XDG_CONFIG_HOME": root.path])
        let first = GTKPreferences(paths: paths)
        XCTAssertEqual(first.defaultStretch, .linear)
        try first.setDefaultStretch(.asinh)
        try first.setDefaultColorMap(.viridis)
        try first.setZScaleContrast(0.4)
        try first.setPixelTableSize(9)
        try first.setRegionColor("green")
        try first.setHasSeenOnboarding(true)

        let second = GTKPreferences(paths: paths)
        XCTAssertEqual(second.defaultStretch, .asinh)
        XCTAssertEqual(second.defaultColorMap, .viridis)
        XCTAssertEqual(second.zscaleContrast, 0.4)
        XCTAssertEqual(second.pixelTableSize, 9)
        XCTAssertEqual(second.regionColor, "green")
        XCTAssertTrue(second.hasSeenOnboarding)
        let stored = try String(contentsOf: second.fileURL, encoding: .utf8)
        XCTAssertTrue(stored.contains("pref.defaultStretch"))
        XCTAssertTrue(stored.contains("pref.pixelTableSize"))

        try second.setZScaleContrast(50)
        try second.setPixelTableSize(8)
        let normalized = GTKPreferences(paths: paths)
        XCTAssertEqual(normalized.zscaleContrast, 0.25)
        XCTAssertEqual(normalized.pixelTableSize, 7)
    }
}
