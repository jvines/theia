import XCTest
@testable import FITSViewerApp

@MainActor final class UserPreferencesTests: XCTestCase {
    func testExistingUserDefaultsKeysRoundTripAndInvalidColorFallsBackToGreen() throws {
        let suite = "UserPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("violet", forKey: "pref.regionColor")
        defaults.set(9, forKey: "pref.pixelTableSize")
        defaults.set(0.7, forKey: "pref.zscaleContrast")

        let preferences = UserPreferences(defaults: defaults)
        XCTAssertEqual(preferences.regionColor, "green")
        XCTAssertEqual(preferences.pixelTableSize, 9)
        XCTAssertEqual(preferences.zscaleContrast, 0.7)

        preferences.regionColor = "red"
        preferences.pixelTableSize = 11
        preferences.zscaleContrast = 0.5
        XCTAssertEqual(defaults.string(forKey: "pref.regionColor"), "red")
        XCTAssertEqual(defaults.integer(forKey: "pref.pixelTableSize"), 11)
        XCTAssertEqual(defaults.double(forKey: "pref.zscaleContrast"), 0.5)
    }

    func testReadoutAndOnboardingUseExistingKeys() throws {
        let suite = "UserPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: defaults)

        XCTAssertEqual(preferences.readoutFrame.rawValue, "icrs")
        XCTAssertFalse(preferences.hasSeenOnboarding)
        preferences.readoutFrame = .galactic
        preferences.hasSeenOnboarding = true
        XCTAssertEqual(defaults.string(forKey: "readoutFrame"), "galactic")
        XCTAssertTrue(defaults.bool(forKey: "hasSeenOnboarding"))
    }
}
