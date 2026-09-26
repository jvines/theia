import Foundation

public enum CommandOrigin: Sendable, Equatable {
    case user
    case script
}

/// A synchronous notification from a document's main-actor state.
public struct SessionEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case displayParametersChanged
        case transformChanged
        case regionsChanged
        case persistedFieldChanged
        case imageRevisionChanged
        case selectionChanged
        case cursorMoved
        case overlaysChanged
        case panelStateChanged
        case playbackChanged
        case jobStatusChanged
    }

    public let kind: Kind
    public let origin: CommandOrigin
    /// Propagation token used by sync consumers to ignore their own echo.
    public let echoTag: UUID?
    public let imageRevision: Int
}
