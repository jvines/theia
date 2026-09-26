import Foundation

/// User-selected contour levels for the currently displayed image.
public struct ContourSpec: Equatable, Sendable {
    public enum Spacing: String, CaseIterable, Identifiable, Equatable, Sendable {
        case linear, log
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    public var enabled: Bool
    public var count: Int
    public var minValue: Double
    public var maxValue: Double
    public var spacing: Spacing

    public init(
        enabled: Bool = false, count: Int = 5,
        minValue: Double = .nan, maxValue: Double = .nan,
        spacing: Spacing = .linear
    ) {
        self.enabled = enabled
        self.count = count
        self.minValue = minValue
        self.maxValue = maxValue
        self.spacing = spacing
    }

    public static func == (lhs: ContourSpec, rhs: ContourSpec) -> Bool {
        lhs.enabled == rhs.enabled &&
        lhs.count == rhs.count &&
        lhs.spacing == rhs.spacing &&
        (lhs.minValue == rhs.minValue || (lhs.minValue.isNaN && rhs.minValue.isNaN)) &&
        (lhs.maxValue == rhs.maxValue || (lhs.maxValue.isNaN && rhs.maxValue.isNaN))
    }

    public func levels() -> [Double] {
        guard enabled, count >= 1, minValue.isFinite, maxValue.isFinite, maxValue > minValue else {
            return []
        }
        if count == 1 { return [(minValue + maxValue) / 2] }
        switch spacing {
        case .linear:
            let step = (maxValue - minValue) / Double(count - 1)
            return (0..<count).map { minValue + Double($0) * step }
        case .log:
            guard minValue > 0 else {
                let step = (maxValue - minValue) / Double(count - 1)
                return (0..<count).map { minValue + Double($0) * step }
            }
            let lo = log(minValue), hi = log(maxValue)
            let step = (hi - lo) / Double(count - 1)
            return (0..<count).map { exp(lo + Double($0) * step) }
        }
    }
}
