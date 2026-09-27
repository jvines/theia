import Foundation
import XCTest
@testable import TheiaKit

final class AppVersionTests: XCTestCase {
    #if os(macOS)
    func testMacBundleVersionMatchesSharedVersion() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repositoryRoot.appendingPathComponent("scripts/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, AppVersion.string)
    }
    #endif
}
