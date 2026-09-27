import Observation
import FITSCore

public struct PhotometryRow: Identifiable, Sendable {
    public let id: Int
    public let region: Region
    public let result: PhotometryResult?
}

public struct PhotometryGroup: Sendable {
    public let tag: String
    public let rows: [PhotometryRow]
    public let totalSum: Double
    public let totalNetFlux: Double?
}

/// Per-document aperture results, recomputed when regions, image, or WCS change.
@MainActor @Observable public final class PhotometryTable {
    public private(set) var regions: [Region] = []
    public private(set) var results: [Int: PhotometryResult] = [:]
    public private(set) var isComputing = false

    private struct InputKey: Equatable {
        let regions: [Region]
        let imageRevision: Int
        let wcs: WCSGeometryKey?
    }

    @ObservationIgnored private var inputKey: InputKey?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let jobs = SessionJobQueue()

    public init() {}

    public var groups: [PhotometryGroup] {
        let rows = regions.enumerated().map { index, region in
            PhotometryRow(id: index, region: region, result: results[index])
        }
        let grouped = Dictionary(grouping: rows, by: { $0.region.attributes["tag"] ?? "" })
        let tags = grouped.keys.sorted { left, right in
            if left.isEmpty { return false }
            if right.isEmpty { return true }
            return left < right
        }
        return tags.map { tag in
            let members = grouped[tag] ?? []
            let sums = members.compactMap { $0.result?.sum }
            let net = members.compactMap { $0.result?.skySubtractedFlux }
            return PhotometryGroup(tag: tag, rows: members,
                                   totalSum: sums.reduce(0, +),
                                   totalNetFlux: net.isEmpty ? nil : net.reduce(0, +))
        }
    }

    public func refresh(regions: [Region], image: FITSImage?, imageRevision: Int, wcs: WCS?) {
        let next = InputKey(regions: regions, imageRevision: imageRevision,
                            wcs: wcs.map { WCSGeometryKey(wcs: $0, width: 0, height: 0) })
        guard next != inputKey else { return }
        inputKey = next
        generation &+= 1
        self.regions = regions
        results = [:]
        guard let image, !regions.isEmpty else {
            jobs.cancel(kind: .photometry)
            isComputing = false
            return
        }
        isComputing = true
        let submittedGeneration = generation
        jobs.enqueue(
            kind: .photometry, imageRevision: submittedGeneration,
            currentRevision: { [weak self] in self?.generation ?? -1 },
            work: {
                var output: [Int: PhotometryResult] = [:]
                for (index, region) in regions.enumerated() {
                    if Task.isCancelled { return nil }
                    if let result = try? Photometry.measureCheckingCancellation(
                        region: region, image: image, wcs: wcs
                    ) {
                        output[index] = result
                    }
                }
                return output
            },
            apply: { [weak self] (output: [Int: PhotometryResult]) in
                self?.results = output
                self?.isComputing = false
            }
        )
    }

    public func idle() async { await jobs.idle() }
}
