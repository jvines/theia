import XCTest
@testable import TheiaGTK

final class GTKDisplayPolicyTests: XCTestCase {
    func testRemoteAndForwardedDisplaysSelectCairo() {
        XCTAssertTrue(GTKDisplayPolicy.shouldUseCairo(environment: ["DISPLAY": "localhost:10.0"]))
        XCTAssertTrue(GTKDisplayPolicy.shouldUseCairo(environment: ["DISPLAY": "cluster:0"]))
        XCTAssertTrue(GTKDisplayPolicy.shouldUseCairo(environment: [
            "WAYLAND_DISPLAY": "wayland-0", "SSH_CONNECTION": "client 22 cluster 4242",
        ]))
    }

    func testLocalDisplaysKeepGtkDefaultAndExplicitOverrideWins() {
        XCTAssertFalse(GTKDisplayPolicy.shouldUseCairo(environment: ["DISPLAY": ":0"]))
        XCTAssertFalse(GTKDisplayPolicy.shouldUseCairo(environment: ["DISPLAY": "unix:1"]))
        XCTAssertFalse(GTKDisplayPolicy.shouldUseCairo(environment: [
            "DISPLAY": "localhost:10.0", "GSK_RENDERER": "ngl",
        ]))
        XCTAssertTrue(GTKDisplayPolicy.isRemoteDisplay(environment: [
            "DISPLAY": "localhost:10.0", "GSK_RENDERER": "ngl",
        ]))
    }
}
