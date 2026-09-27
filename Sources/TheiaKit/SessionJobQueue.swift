import Foundation

/// The kind determines whether a newer request replaces unfinished work.
public enum SessionJobKind: Hashable, Sendable {
    case displayImage
    case contours
    case photometry
    case statistics
    case radialProfile
    case growthCurve
    case sourceDetection
    case catalog
    case imageOperation
    case export

    var latestWins: Bool {
        switch self {
        case .displayImage, .contours, .photometry, .statistics, .radialProfile, .growthCurve: true
        case .sourceDetection, .catalog, .imageOperation, .export: false
        }
    }
}

/// Serial, per-document work queue. Work runs off the main actor; results return
/// only when their request and input image revision are still current.
@MainActor public final class SessionJobQueue {
    private var nextID: UInt64 = 0
    private var tail: Task<Void, Never>?
    private var active: [UInt64: Task<Void, Never>] = [:]
    private var activeKinds: [UInt64: SessionJobKind] = [:]
    private var latest: [SessionJobKind: UInt64] = [:]

    public init() {}

    public func enqueue<Value: Sendable>(
        kind: SessionJobKind,
        imageRevision: Int,
        currentRevision: @escaping @MainActor @Sendable () -> Int,
        work: @escaping @Sendable () async -> Value?,
        apply: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        let id = nextID
        nextID &+= 1
        if kind.latestWins {
            if let prior = latest[kind] { active[prior]?.cancel() }
            latest[kind] = id
        }
        let predecessor = tail
        let task = Task.detached(priority: .userInitiated) { [self] in
            await predecessor?.value
            guard !Task.isCancelled else {
                await finish(id: id, kind: kind, imageRevision: imageRevision,
                             value: Optional<Value>.none, cancelled: true,
                             currentRevision: currentRevision, apply: apply)
                return
            }
            let value = await work()
            let cancelled = Task.isCancelled
            await finish(id: id, kind: kind, imageRevision: imageRevision,
                         value: value, cancelled: cancelled,
                         currentRevision: currentRevision, apply: apply)
        }
        active[id] = task
        activeKinds[id] = kind
        tail = task
    }

    public func cancel(kind: SessionJobKind) {
        if kind.latestWins { latest[kind] = nil }
        for (id, activeKind) in activeKinds where activeKind == kind {
            active[id]?.cancel()
        }
    }

    public func hasActive(kind: SessionJobKind) -> Bool {
        activeKinds.values.contains(kind)
    }

    public func idle() async {
        while !active.isEmpty {
            await tail?.value
        }
    }

    private func finish<Value: Sendable>(
        id: UInt64, kind: SessionJobKind, imageRevision: Int,
        value: Value?, cancelled: Bool,
        currentRevision: @MainActor @Sendable () -> Int,
        apply: @MainActor @Sendable (Value) -> Void
    ) {
        if !cancelled, let value,
           (!kind.latestWins || latest[kind] == id),
           currentRevision() == imageRevision {
            apply(value)
        }
        active[id] = nil
        activeKinds[id] = nil
        if latest[kind] == id { latest[kind] = nil }
    }
}
