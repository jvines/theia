import FITSCore

@frozen public struct RGBA8: Sendable, Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public static let opaqueBlack = RGBA8(r: 0, g: 0, b: 0, a: 255)

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(_ rgb: SIMD3<Float>) {
        func byte(_ value: Float) -> UInt8 {
            UInt8((min(1, max(0, value)) * 255).rounded())
        }
        self.init(r: byte(rgb.x), g: byte(rgb.y), b: byte(rgb.z))
    }
}

/// The same integer-indexed table is consumed by the CPU and Metal renderers.
public struct ColorTable: Sendable {
    public let entries: [RGBA8]

    public static func cached(_ map: ColorMap) -> ColorTable {
        switch map {
        case .gray: return gray
        case .invertedGray: return invertedGray
        case .viridis: return viridis
        case .magma: return magma
        case .plasma: return plasma
        }
    }

    private static let gray = ColorTable(map: .gray)
    private static let invertedGray = ColorTable(map: .invertedGray)
    private static let viridis = ColorTable(map: .viridis)
    private static let magma = ColorTable(map: .magma)
    private static let plasma = ColorTable(map: .plasma)

    public init(map: ColorMap) {
        let reference = (0...65_536).map { RGBA8(map.sample(Float($0) / 65_536)) }
        var size = 2
        while true {
            let entries = (0..<size).map { RGBA8(map.sample(Float($0) / Float(size - 1))) }
            if Self.adjacentWithinOneLSB(entries),
               Self.uniformSweepWithinOneLSB(entries, reference),
               Self.intervalSweepWithinOneLSB(entries, map: map) {
                self.entries = entries
                return
            }
            size *= 2
        }
    }

    public func color(for value: Float) -> RGBA8 {
        if value.isNaN { return .opaqueBlack }
        let n = min(1, max(0, value))
        let index = Int((n * Float(entries.count - 1) + 0.5).rounded(.down))
        return entries[index]
    }

    private static func adjacentWithinOneLSB(_ entries: [RGBA8]) -> Bool {
        for i in 1..<entries.count where !withinOneLSB(entries[i - 1], entries[i]) {
            return false
        }
        return true
    }

    private static func uniformSweepWithinOneLSB(_ entries: [RGBA8], _ reference: [RGBA8]) -> Bool {
        for i in reference.indices {
            let n = Float(i) / Float(reference.count - 1)
            let index = Int((n * Float(entries.count - 1) + 0.5).rounded(.down))
            if !withinOneLSB(entries[index], reference[i]) { return false }
        }
        return true
    }

    private static func intervalSweepWithinOneLSB(_ entries: [RGBA8], map: ColorMap) -> Bool {
        // Check inside each lookup interval, especially around the midpoint
        // where the nearest-entry decision changes. A fixed uniform sweep can
        // align with entries and miss the largest errors.
        for i in 0..<(entries.count - 1) {
            for fraction in [Float(0.25), 0.49, 0.5, 0.51, 0.75] {
                let n = (Float(i) + fraction) / Float(entries.count - 1)
                let index = Int((n * Float(entries.count - 1) + 0.5).rounded(.down))
                if !withinOneLSB(entries[index], RGBA8(map.sample(n))) { return false }
            }
        }
        return true
    }

    private static func withinOneLSB(_ a: RGBA8, _ b: RGBA8) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= 1 &&
        abs(Int(a.g) - Int(b.g)) <= 1 &&
        abs(Int(a.b) - Int(b.b)) <= 1 &&
        abs(Int(a.a) - Int(b.a)) <= 1
    }
}
