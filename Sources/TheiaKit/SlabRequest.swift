import Foundation

/// The cube selection captured before asking for an inclusive plane range.
public struct SlabRequest: Sendable, Equatable {
    public let id: UUID
    public let documentID: UUID
    public let hduIndex: Int
    public let imageRevision: Int
    public let planeCount: Int

    @MainActor init(session: DocumentSession) {
        id = UUID()
        documentID = session.id
        hduIndex = session.hdu
        imageRevision = session.imageRevision
        planeCount = session.file.hdus[session.hdu].planeCount
    }
}
