import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKPrintJobTests: XCTestCase {
    @MainActor func testDisplayedImageProducesPrintablePDF() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fixture,
                                      file: try FITSFile(data: Data(contentsOf: fixture)))
        let snapshot = try XCTUnwrap(GTKPrintSnapshot(session: session))
        let pdf = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-print-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdf) }
        try snapshot.writePDF(to: pdf)
        let content = try Data(contentsOf: pdf)
        XCTAssertTrue(content.starts(with: Data("%PDF-".utf8)))
        XCTAssertTrue(String(decoding: content.suffix(32), as: UTF8.self).contains("%%EOF"))
        XCTAssertGreaterThan(content.count, 500)
    }
}
