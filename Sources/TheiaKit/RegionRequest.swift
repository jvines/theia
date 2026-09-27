import Foundation
import FITSCore

/// Region contents captured when Save is chosen, independent of later edits.
public struct RegionSaveSnapshot: Sendable, Equatable {
    public let id: UUID
    public let documentID: UUID
    public let regions: [Region]

    @MainActor init(session: DocumentSession) {
        id = UUID()
        documentID = session.id
        regions = session.regions
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    public func write(to url: URL) throws {
        try Data(RegionFile.format(regions).utf8).write(to: url, options: .atomic)
    }
}

/// Identifies one pending region import without binding it to the current HDU.
public struct RegionLoadRequest: Sendable, Equatable {
    public let id: UUID
    public let documentID: UUID

    @MainActor init(session: DocumentSession) {
        id = UUID()
        documentID = session.id
    }
}
