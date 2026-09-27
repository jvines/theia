import XCTest
@testable import TheiaKit

final class SessionJobQueueTests: XCTestCase {
    func testJobsApplyInSubmissionOrder() async {
        let (jobs, probe) = await MainActor.run { (SessionJobQueue(), JobProbe()) }
        let gate = JobGate()
        await MainActor.run {
            jobs.enqueue(kind: .export, imageRevision: 0,
                         currentRevision: { probe.revision },
                         work: { await gate.wait(); return 1 },
                         apply: { probe.applied.append($0) })
            jobs.enqueue(kind: .export, imageRevision: 0,
                         currentRevision: { probe.revision },
                         work: { 2 },
                         apply: { probe.applied.append($0) })
        }
        await gate.untilStarted()
        await gate.open()
        await jobs.idle()
        let applied = await MainActor.run { probe.applied }
        XCTAssertEqual(applied, [1, 2])
    }

    func testLatestContoursRequestSuppressesRunningPredecessor() async {
        let (jobs, probe) = await MainActor.run { (SessionJobQueue(), JobProbe()) }
        let gate = JobGate()
        await MainActor.run {
            jobs.enqueue(kind: .contours, imageRevision: 0,
                         currentRevision: { probe.revision },
                         work: { await gate.wait(); return 1 },
                         apply: { probe.applied.append($0) })
        }
        await gate.untilStarted()
        await MainActor.run {
            jobs.enqueue(kind: .contours, imageRevision: 0,
                         currentRevision: { probe.revision },
                         work: { 2 },
                         apply: { probe.applied.append($0) })
        }
        await gate.open()
        await jobs.idle()
        let applied = await MainActor.run { probe.applied }
        XCTAssertEqual(applied, [2])
    }

    func testResultFromOldImageRevisionIsDiscarded() async {
        let (jobs, probe) = await MainActor.run { (SessionJobQueue(), JobProbe()) }
        let gate = JobGate()
        await MainActor.run {
            jobs.enqueue(kind: .statistics, imageRevision: 0,
                         currentRevision: { probe.revision },
                         work: { await gate.wait(); return 1 },
                         apply: { probe.applied.append($0) })
        }
        await gate.untilStarted()
        await MainActor.run { probe.revision = 1 }
        await gate.open()
        await jobs.idle()
        let applied = await MainActor.run { probe.applied }
        XCTAssertTrue(applied.isEmpty)
    }

    func testExplicitCancelStopsNonSupersedingDetectionJob() async {
        let (jobs, probe) = await MainActor.run { (SessionJobQueue(), JobProbe()) }
        let gate = JobGate()
        await MainActor.run {
            jobs.enqueue(kind: .sourceDetection, imageRevision: 0,
                         currentRevision: { probe.revision },
                         work: { await gate.wait(); return 1 },
                         apply: { probe.applied.append($0) })
        }
        await gate.untilStarted()
        await MainActor.run { jobs.cancel(kind: .sourceDetection) }
        await gate.open()
        await jobs.idle()
        let applied = await MainActor.run { probe.applied }
        XCTAssertTrue(applied.isEmpty)
    }
}

@MainActor private final class JobProbe {
    var revision = 0
    var applied: [Int] = []
}

private actor JobGate {
    private var started = false
    private var openState = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if openState { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func untilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func open() {
        openState = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
