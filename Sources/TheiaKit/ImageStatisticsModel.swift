import Foundation
import Observation
import FITSCore

public struct ImageStatisticsPercentile: Sendable {
    public let percent: Double
    public let value: Double
}

public struct ImageStatisticsSummary: Sendable {
    public static let percentilePoints: [Double] = [0.5, 1, 5, 25, 50, 75, 95, 99, 99.5]

    public let width: Int
    public let height: Int
    public let n: Int
    public let nans: Int
    public let min: Double
    public let max: Double
    public let mean: Double
    public let median: Double
    public let stddev: Double
    public let percentiles: [ImageStatisticsPercentile]

    public static func calculate(
        image: FITSImage,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> ImageStatisticsSummary {
        let values = try image.physicalValuesCheckingCancellation(
            checkCancellation: checkCancellation
        )
        var nans = 0
        var clean: [Double] = []
        clean.reserveCapacity(values.count)
        for index in values.indices {
            if index & 8_191 == 0 { try checkCancellation() }
            let value = values[index]
            if value.isNaN { nans += 1 } else { clean.append(value) }
        }
        let n = clean.count
        var sum = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for index in clean.indices {
            if index & 8_191 == 0 { try checkCancellation() }
            let value = clean[index]
            sum += value
            minimum = Swift.min(minimum, value)
            maximum = Swift.max(maximum, value)
        }
        let mean = n == 0 ? 0 : sum / Double(n)
        var varianceSum = 0.0
        for index in clean.indices {
            if index & 8_191 == 0 { try checkCancellation() }
            varianceSum += (clean[index] - mean) * (clean[index] - mean)
        }
        let variance = n <= 1 ? 0 : varianceSum / Double(n - 1)
        var ranked: [Double] = []
        if n > 0 {
            let ranks = [n / 2] + percentilePoints.map { percent in
                Swift.max(0, Swift.min(n - 1,
                    Int((percent / 100) * Double(n - 1))))
            }
            ranked = try selectRanks(in: &clean, ranks: ranks,
                                     checkCancellation: checkCancellation)
        }
        let percentiles = percentilePoints.enumerated().map { index, percent in
            ImageStatisticsPercentile(percent: percent,
                                      value: n == 0 ? .nan : ranked[index + 1])
        }
        return ImageStatisticsSummary(
            width: image.width, height: image.height, n: n, nans: nans,
            min: n == 0 ? 0 : minimum, max: n == 0 ? 0 : maximum,
            mean: mean, median: n == 0 ? 0 : ranked[0],
            stddev: variance.squareRoot(), percentiles: percentiles
        )
    }

    /// Select only the ranks displayed by the panel. The in-place three-way
    /// partitions let canceled jobs stop during the dominant computation.
    static func selectRanks(
        in values: inout [Double], ranks: [Int],
        checkCancellation: () throws -> Void
    ) throws -> [Double] {
        guard !ranks.isEmpty else { return [] }
        precondition(ranks.allSatisfy { values.indices.contains($0) })
        var selected: [Int: Double] = [:]
        for target in Set(ranks).sorted() {
            var left = 0
            var right = values.count - 1
            while left <= right {
                try checkCancellation()
                let midpoint = left + (right - left) / 2
                let pivot = [values[left], values[midpoint], values[right]].sorted()[1]
                var lower = left
                var cursor = left
                var upper = right
                var visited = 0
                while cursor <= upper {
                    if visited & 8_191 == 0 { try checkCancellation() }
                    visited += 1
                    if values[cursor] < pivot {
                        values.swapAt(lower, cursor)
                        lower += 1
                        cursor += 1
                    } else if values[cursor] > pivot {
                        values.swapAt(cursor, upper)
                        upper -= 1
                    } else {
                        cursor += 1
                    }
                }
                if target < lower {
                    right = lower - 1
                } else if target > upper {
                    left = upper + 1
                } else {
                    selected[target] = values[target]
                    break
                }
            }
        }
        return ranks.map { selected[$0]! }
    }

    public static func format(_ value: Double) -> String {
        if abs(value) >= 1e4 || (value != 0 && abs(value) < 0.01) {
            return String(format: "%.4g", value)
        }
        return String(format: "%.4f", value)
    }
}

/// Per-document statistics for the current displayed image.
@MainActor @Observable public final class ImageStatisticsModel {
    public private(set) var summary: ImageStatisticsSummary?
    public private(set) var isComputing = false

    @ObservationIgnored private var inputRevision: Int?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let jobs = SessionJobQueue()

    public init() {}

    public func refresh(image: FITSImage?, imageRevision: Int, force: Bool = false) {
        guard force || imageRevision != inputRevision else { return }
        inputRevision = imageRevision
        generation &+= 1
        summary = nil
        guard let image else {
            jobs.cancel(kind: .statistics)
            isComputing = false
            return
        }
        isComputing = true
        let submittedGeneration = generation
        jobs.enqueue(
            kind: .statistics, imageRevision: submittedGeneration,
            currentRevision: { [weak self] in self?.generation ?? -1 },
            work: {
                try? ImageStatisticsSummary.calculate(image: image)
            },
            apply: { [weak self] (result: ImageStatisticsSummary) in
                self?.summary = result
                self?.isComputing = false
            }
        )
    }

    public func idle() async { await jobs.idle() }
}
