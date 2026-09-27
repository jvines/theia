import XCTest
import FITSCore
@testable import TheiaKit

final class ImageStatisticsModelTests: XCTestCase {
    func testSummaryPreservesDisplayedImageStatisticsAndPercentileRanks() throws {
        let image = FITSImage.fromFloat32(pixels: [1, 2, 3, .nan], width: 2, height: 2)
        let summary = try ImageStatisticsSummary.calculate(image: image)
        XCTAssertEqual(summary.width, 2)
        XCTAssertEqual(summary.height, 2)
        XCTAssertEqual(summary.n, 3)
        XCTAssertEqual(summary.nans, 1)
        XCTAssertEqual(summary.min, 1)
        XCTAssertEqual(summary.max, 3)
        XCTAssertEqual(summary.mean, 2)
        XCTAssertEqual(summary.median, 2)
        XCTAssertEqual(summary.stddev, 1)
        XCTAssertEqual(summary.percentiles.count, 9)
        XCTAssertEqual(summary.percentiles.first?.percent, 0.5)
        XCTAssertEqual(summary.percentiles.first?.value, 1)
        XCTAssertEqual(summary.percentiles.last?.percent, 99.5)
        XCTAssertEqual(summary.percentiles.last?.value, 2)
    }

    func testSessionModelRecomputesForImageRevisionAndExplicitRefresh() async throws {
        let model = await MainActor.run { ImageStatisticsModel() }
        let first = FITSImage.fromFloat32(pixels: [1, 1, 1, 1], width: 2, height: 2)
        let second = FITSImage.fromFloat32(pixels: [2, 2, 2, 2], width: 2, height: 2)
        await MainActor.run { model.refresh(image: first, imageRevision: 1) }
        await model.idle()
        let firstSum = await MainActor.run { model.summary?.mean }
        XCTAssertEqual(firstSum, 1)
        await MainActor.run { model.refresh(image: second, imageRevision: 2) }
        await model.idle()
        let secondSum = await MainActor.run { model.summary?.mean }
        XCTAssertEqual(secondSum, 2)
        await MainActor.run { model.refresh(image: first, imageRevision: 2, force: true) }
        await model.idle()
        let recomputed = await MainActor.run { model.summary?.mean }
        XCTAssertEqual(recomputed, 1)
    }

    func testRankSelectionMatchesSortedReferenceWithRepeatedValues() throws {
        for count in 1...99 {
            var values = (0..<count).map { Double(($0 * 37 + count * 11) % 23 - 11) }
            let ranks = [0, count / 4, count / 2, count - 1]
            let selected = try ImageStatisticsSummary.selectRanks(
                in: &values, ranks: ranks, checkCancellation: {}
            )
            let sorted = values.sorted()
            XCTAssertEqual(selected, ranks.map { sorted[$0] },
                           "wrong rank for \(count) values")
        }
    }

    func testRankSelectionChecksCancellationWithinLargePartition() {
        enum Stop: Error { case requested }
        var values = (0..<65_536).map { Double(($0 * 37) % 997) }
        var checks = 0
        XCTAssertThrowsError(try ImageStatisticsSummary.selectRanks(
            in: &values, ranks: [values.count / 2],
            checkCancellation: {
                checks += 1
                if checks == 4 { throw Stop.requested }
            }
        )) { error in
            XCTAssertTrue(error is Stop)
        }
        XCTAssertEqual(checks, 4)
    }
}
