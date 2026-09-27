import Foundation
import XCTest
@testable import TheiaKit

final class ScriptingTokenStoreTests: XCTestCase {
    func testTokenIsRandomPersistedAndOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-token-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scripting-token")
        let store = ScriptingTokenStore(url: file)

        let first = try store.loadOrCreate()
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(try ScriptingTokenStore(url: file).loadOrCreate(), first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testBearerAuthorizationRequiresExactToken() throws {
        let token = String(repeating: "a", count: 64)
        XCTAssertTrue(ScriptingTokenStore.authorise(headerValue: "Bearer \(token)", token: token))
        XCTAssertTrue(ScriptingTokenStore.authorise(headerValue: "bearer \(token)", token: token))
        XCTAssertFalse(ScriptingTokenStore.authorise(headerValue: nil, token: token))
        XCTAssertFalse(ScriptingTokenStore.authorise(headerValue: "Basic \(token)", token: token))
        XCTAssertFalse(ScriptingTokenStore.authorise(headerValue: "Bearer \(String(repeating: "b", count: 64))", token: token))
        XCTAssertFalse(ScriptingTokenStore.authorise(headerValue: "Bearer \(token.dropLast())", token: token))
    }

    func testInvalidExistingTokenIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-token-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scripting-token")
        try "bad".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ScriptingTokenStore(url: file).loadOrCreate())
    }
}
