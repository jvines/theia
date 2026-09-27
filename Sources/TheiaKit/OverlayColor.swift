import Foundation

/// Platform-neutral RGB colour used by image overlays.
public struct OverlayColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let defaultRegion = OverlayColor(red: 0, green: 1, blue: 0)

    public static func parse(_ raw: String?) -> OverlayColor? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch name {
        case "red": return .init(red: 1, green: 0, blue: 0)
        case "green": return defaultRegion
        case "blue": return .init(red: 0, green: 0, blue: 1)
        case "yellow": return .init(red: 1, green: 1, blue: 0)
        case "cyan": return .init(red: 0, green: 1, blue: 1)
        case "magenta": return .init(red: 1, green: 0, blue: 1)
        case "white": return .init(red: 1, green: 1, blue: 1)
        case "black": return .init(red: 0, green: 0, blue: 0)
        case "violet", "purple": return .init(red: 0.42, green: 0.32, blue: 0.78)
        default:
            guard name.hasPrefix("#"), name.count == 7,
                  let r = UInt8(name.dropFirst().prefix(2), radix: 16),
                  let g = UInt8(name.dropFirst(3).prefix(2), radix: 16),
                  let b = UInt8(name.dropFirst(5).prefix(2), radix: 16) else { return nil }
            return .init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }
}
