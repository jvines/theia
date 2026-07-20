import Foundation

public enum ImageArithmetic {
    public enum ArithmeticError: Error, Equatable {
        case dimensionMismatch
    }

    /// Binary per-pixel operations between two FITSImages of the same shape.
    public enum BinaryOp: String, CaseIterable, Sendable {
        case sum, difference, ratio, multiply, mask

        public var label: String {
            switch self {
            case .sum: return "Sum"
            case .difference: return "Difference"
            case .ratio: return "Ratio"
            case .multiply: return "Multiply"
            case .mask: return "Mask (B = NaN → A)"
            }
        }
    }

    /// Unary per-pixel transforms.
    public enum UnaryOp: String, CaseIterable, Sendable {
        case log10, sqrt, square, abs, negate

        public var label: String {
            switch self {
            case .log10: return "Log10"
            case .sqrt:  return "Sqrt"
            case .square:return "Square"
            case .abs:   return "Abs"
            case .negate:return "Negate"
            }
        }
    }

    public static func difference(_ a: FITSImage, minus b: FITSImage) throws -> FITSImage {
        try combined(a, b, op: .difference)
    }

    public static func combined(_ a: FITSImage, _ b: FITSImage, op: BinaryOp) throws -> FITSImage {
        guard a.width == b.width, a.height == b.height else {
            throw ArithmeticError.dimensionMismatch
        }
        let aPx = a.normalizedFloat32()
        let bPx = b.normalizedFloat32()
        var out = [Float](repeating: 0, count: aPx.count)
        for i in 0..<aPx.count {
            let av = aPx[i], bv = bPx[i]
            if av.isNaN || bv.isNaN {
                out[i] = (op == .mask && bv.isNaN) ? av : .nan
                continue
            }
            switch op {
            case .sum:        out[i] = av + bv
            case .difference: out[i] = av - bv
            case .ratio:      out[i] = bv == 0 ? .nan : av / bv
            case .multiply:   out[i] = av * bv
            case .mask:       out[i] = bv.isFinite ? av : .nan
            }
        }
        return FITSImage.fromFloat32(pixels: out, width: a.width, height: a.height)
    }

    public static func unary(_ image: FITSImage, op: UnaryOp) -> FITSImage {
        let px = image.normalizedFloat32()
        var out = [Float](repeating: 0, count: px.count)
        for i in 0..<px.count {
            let v = px[i]
            if v.isNaN { out[i] = .nan; continue }
            switch op {
            case .log10:
                out[i] = v <= 0 ? .nan : Foundation.log10(v)
            case .sqrt:
                out[i] = v < 0 ? .nan : Foundation.sqrt(v)
            case .square:
                out[i] = v * v
            case .abs:
                out[i] = Swift.abs(v)
            case .negate:
                out[i] = -v
            }
        }
        return FITSImage.fromFloat32(pixels: out, width: image.width, height: image.height)
    }
}
