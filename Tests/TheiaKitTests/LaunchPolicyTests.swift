import XCTest
@testable import TheiaKit

final class LaunchPolicyTests: XCTestCase {
    func testFirstRunShowsOnboardingEvenWhenArgvOpenedADocument() {
        XCTAssertEqual(LaunchPolicy.initialWindow(hasSeenOnboarding: false,
                                                  openDocumentCount: 1), .onboarding)
    }

    func testReturningUserSeesWelcomeOnlyWithoutDocuments() {
        XCTAssertEqual(LaunchPolicy.initialWindow(hasSeenOnboarding: true,
                                                  openDocumentCount: 0), .welcome)
        XCTAssertNil(LaunchPolicy.initialWindow(hasSeenOnboarding: true,
                                                openDocumentCount: 2))
    }

    func testReopenShowsWelcomeOnlyForEmptyHiddenWorkspace() {
        XCTAssertEqual(LaunchPolicy.reopenWindow(hasVisibleWindows: false,
                                                 openDocumentCount: 0), .welcome)
        XCTAssertNil(LaunchPolicy.reopenWindow(hasVisibleWindows: true,
                                               openDocumentCount: 0))
        XCTAssertNil(LaunchPolicy.reopenWindow(hasVisibleWindows: false,
                                               openDocumentCount: 1))
    }
}
