/// The selected panel within a document's inspector.
public enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case header = "Header"
    case regions = "Regions"
    case photometry = "Photometry"
    case stats = "Stats"

    public var id: String { rawValue }
}
