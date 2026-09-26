import Foundation

public struct FITSImage: Sendable {
    public enum PixelType: Sendable {
        case uint8
        case int16
        case int32
        case float32
        case float64
    }

    public let width: Int
    public let height: Int
    public let pixelType: PixelType
    public let bscale: Double
    public let bzero: Double
    public let blank: Int64?

    /// Raw big-endian pixel bytes. `internal` rather than `private` so other
    /// FITSCore types (e.g. `FITSWriter`) can byte-copy without decoding.
    let pixels: Data

    /// Synthesizes a `float32`-storage image from a row-major Float buffer. Useful for
    /// reprojected / differenced images that don't come from a `FITSHDU`.
    public static func fromFloat32(pixels: [Float], width: Int, height: Int) -> FITSImage {
        precondition(pixels.count == width * height, "pixel count must equal width × height")
        // Build the big-endian byte stream in a single contiguous allocation:
        // one bulk byte-swap pass over a UInt32 buffer, then wrap as Data.
        let bigEndianBits: [UInt32] = pixels.map { $0.bitPattern.bigEndian }
        let data = bigEndianBits.withUnsafeBufferPointer { buf -> Data in
            buf.baseAddress.flatMap { Data(bytes: $0, count: buf.count * MemoryLayout<UInt32>.size) } ?? Data()
        }
        return FITSImage(_unchecked: width, height: height, pixelType: .float32, pixels: data, bscale: 1, bzero: 0, blank: nil)
    }

    private init(
        _unchecked width: Int,
        height: Int,
        pixelType: PixelType,
        pixels: Data,
        bscale: Double,
        bzero: Double,
        blank: Int64?
    ) {
        self.width = width
        self.height = height
        self.pixelType = pixelType
        self.pixels = pixels
        self.bscale = bscale
        self.bzero = bzero
        self.blank = blank
    }

    /// `plane` selects which slice of a 3D cube to expose as a 2D image. Ignored
    /// when NAXIS=2. Throws if NAXIS is anything other than 2 or 3, or if `plane`
    /// is out of range.
    public init(hdu: FITSHDU, plane: Int = 0) throws {
        let axes = hdu.axes
        // Accept NAXIS>=2. Axes 1 & 2 are the image width/height; every axis beyond
        // the first two contributes to a flattened plane stack whose size is the
        // product of their lengths. A degenerate cube like [RA,Dec,Freq=1,Stokes=1]
        // then has a single plane and renders as a 2D image; a real cube stacks its
        // planes contiguously in row-major order. Byte-identical to the previous
        // NAXIS=2 / NAXIS=3 handling (depth 1 / depth NAXIS3 respectively).
        guard hdu.naxis >= 2, axes.count == hdu.naxis, axes[0] > 0, axes[1] > 0 else {
            throw FITSError.invalidHeader("FITSImage requires NAXIS>=2 with positive axes 1-2 (got \(hdu.naxis), axes \(axes))")
        }
        let w = axes[0], h = axes[1]
        var depth = 1
        for i in 2..<axes.count {
            guard axes[i] > 0 else {
                throw FITSError.invalidHeader("invalid NAXIS dimensions \(axes)")
            }
            let r = depth.multipliedReportingOverflow(by: axes[i])
            guard !r.overflow else { throw FITSError.invalidHeader("plane count overflow") }
            depth = r.partialValue
        }
        guard plane >= 0, plane < depth else {
            throw FITSError.invalidHeader("plane \(plane) out of range [0, \(depth))")
        }
        let bpp = abs(hdu.bitpix) / 8
        guard bpp > 0 else {
            throw FITSError.unsupportedBitpix(hdu.bitpix)
        }
        // Overflow-checked: bytesPerPlane = w * h * bpp; start = plane * bytesPerPlane.
        let whResult = w.multipliedReportingOverflow(by: h)
        guard !whResult.overflow else { throw FITSError.invalidHeader("plane dims overflow") }
        let bppResult = whResult.partialValue.multipliedReportingOverflow(by: bpp)
        guard !bppResult.overflow else { throw FITSError.invalidHeader("plane bytes overflow") }
        let bytesPerPlane = bppResult.partialValue
        let offsetResult = plane.multipliedReportingOverflow(by: bytesPerPlane)
        guard !offsetResult.overflow else { throw FITSError.invalidHeader("plane offset overflow") }
        let startOffset = offsetResult.partialValue
        let endOffsetResult = startOffset.addingReportingOverflow(bytesPerPlane)
        guard !endOffsetResult.overflow else { throw FITSError.invalidHeader("plane end overflow") }
        let start = hdu.data.startIndex + startOffset
        let end = hdu.data.startIndex + endOffsetResult.partialValue
        guard end <= hdu.data.endIndex else {
            throw FITSError.truncated
        }
        self.width = w
        self.height = h
        // Slice via subscript so an mmap-backed HDU stays mmap-backed; the
        // resulting Data has non-zero startIndex but `physicalValues` uses
        // withUnsafeBytes which honours that.
        self.pixels = hdu.data[start..<end]
        switch hdu.bitpix {
        case 8: self.pixelType = .uint8
        case 16: self.pixelType = .int16
        case 32: self.pixelType = .int32
        case -32: self.pixelType = .float32
        case -64: self.pixelType = .float64
        default: throw FITSError.unsupportedBitpix(hdu.bitpix)
        }
        self.bscale = hdu.header["BSCALE"]?.doubleValue ?? 1.0
        self.bzero = hdu.header["BZERO"]?.doubleValue ?? 0.0
        switch hdu.bitpix {
        case 8, 16, 32, 64:
            self.blank = hdu.header["BLANK"]?.intValue.map(Int64.init)
        default:
            self.blank = nil
        }
    }

    public func physicalValue(x: Int, y: Int) -> Double {
        // C3: bounds-checked public API — OOB indices return NaN instead of
        // trapping deep in Data subscripting. Callers in FITSRender / Photometry
        // / Profiles depend on this for graceful sampling near edges.
        guard x >= 0, x < width, y >= 0, y < height else { return .nan }
        let raw = rawValue(x: x, y: y)
        // C2: NaN check must come BEFORE the BLANK compare — `Int64(.nan)` traps.
        // `Int64(exactly:)` is also belt-and-braces for non-integer Doubles.
        if raw.isNaN { return .nan }
        if let blank, let asInt = Int64(exactly: raw), asInt == blank {
            return .nan
        }
        return bzero + bscale * raw
    }

    /// Returns the image as a row-major `Float32` buffer suitable for upload to a
    /// Metal texture or other GPU pipeline. NaN is preserved (from BLANK or float NaN).
    public func normalizedFloat32() -> [Float] {
        var out = [Float]()
        out.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                out.append(Float(physicalValue(x: x, y: y)))
            }
        }
        return out
    }

    /// Returns the image as a row-major `[Double]` buffer of physical values.
    ///
    /// Specialised per pixel type with a single `withUnsafeBytes` pass and
    /// fixed-stride byte assembly inside the loop, avoiding the per-pixel
    /// switch dispatch that the previous version paid for every sample. On
    /// 4k×4k float32 images this is the dominant cost of the photometry /
    /// stats panel; collapsing the dispatch makes it noticeably tighter.
    public func physicalValues() -> [Double] {
        let count = width * height
        var out = [Double](repeating: 0, count: count)
        guard count > 0 else { return out }
        let scale = bscale
        let zero = bzero
        let blankInt = blank
        pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            switch pixelType {
            case .uint8:
                let p = base.assumingMemoryBound(to: UInt8.self)
                for i in 0..<count {
                    let v = Double(p[i])
                    out[i] = applyScaling(v, scale: scale, zero: zero, blank: blankInt)
                }
            case .int16:
                for i in 0..<count {
                    let off = i * 2
                    let hi = UInt16(base.load(fromByteOffset: off,     as: UInt8.self))
                    let lo = UInt16(base.load(fromByteOffset: off + 1, as: UInt8.self))
                    let raw16 = Int16(bitPattern: (hi << 8) | lo)
                    out[i] = applyScaling(Double(raw16), scale: scale, zero: zero, blank: blankInt)
                }
            case .int32:
                for i in 0..<count {
                    let off = i * 4
                    let b0 = UInt32(base.load(fromByteOffset: off,     as: UInt8.self))
                    let b1 = UInt32(base.load(fromByteOffset: off + 1, as: UInt8.self))
                    let b2 = UInt32(base.load(fromByteOffset: off + 2, as: UInt8.self))
                    let b3 = UInt32(base.load(fromByteOffset: off + 3, as: UInt8.self))
                    let bits = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
                    out[i] = applyScaling(Double(Int32(bitPattern: bits)), scale: scale, zero: zero, blank: blankInt)
                }
            case .float32:
                for i in 0..<count {
                    let off = i * 4
                    let b0 = UInt32(base.load(fromByteOffset: off,     as: UInt8.self))
                    let b1 = UInt32(base.load(fromByteOffset: off + 1, as: UInt8.self))
                    let b2 = UInt32(base.load(fromByteOffset: off + 2, as: UInt8.self))
                    let b3 = UInt32(base.load(fromByteOffset: off + 3, as: UInt8.self))
                    let bits = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
                    let f = Float(bitPattern: bits)
                    out[i] = f.isNaN ? .nan : Double(f) * scale + zero
                }
            case .float64:
                for i in 0..<count {
                    let off = i * 8
                    var bits: UInt64 = 0
                    for j in 0..<8 {
                        bits = (bits << 8) | UInt64(base.load(fromByteOffset: off + j, as: UInt8.self))
                    }
                    let d = Double(bitPattern: bits)
                    out[i] = d.isNaN ? .nan : d * scale + zero
                }
            }
        }
        return out
    }

    @inline(__always)
    private func applyScaling(_ raw: Double, scale: Double, zero: Double, blank: Int64?) -> Double {
        if raw.isNaN { return .nan }
        if let b = blank, let asInt = Int64(exactly: raw), asInt == b {
            return .nan
        }
        return zero + scale * raw
    }

    /// Default display range via IRAF zscale.
    public func defaultRange(contrast: Double = 0.25) -> (z1: Double, z2: Double)? {
        PixelStatistics.zscaleSampled(pixelCount: width * height, contrast: contrast) { index in
            physicalValue(x: index % width, y: index / width)
        }
    }

    /// Full finite range without allocating a decoded pixel array.
    public func physicalMinMax() -> (min: Double, max: Double)? {
        var lo = Double.infinity
        var hi = -Double.infinity
        for y in 0..<height {
            for x in 0..<width {
                let value = physicalValue(x: x, y: y)
                guard value.isFinite else { continue }
                lo = Swift.min(lo, value)
                hi = Swift.max(hi, value)
            }
        }
        return lo <= hi ? (lo, hi) : nil
    }

    /// How to combine values along the planes of a cube into a single 2D image.
    public enum CollapseMode: String, CaseIterable, Sendable {
        case sum, mean, median, max

        public var label: String {
            switch self {
            case .sum: return "Sum"
            case .mean: return "Mean"
            case .median: return "Median"
            case .max: return "Max"
            }
        }
    }

    /// Collapses an `NAXIS=3` cube along the plane axis into a 2D `FITSImage`. NaN
    /// values are skipped in `mean` / `median`; `sum` propagates NaN if all entries
    /// at a pixel are NaN.
    ///
    /// Throws `FITSError.invalidHeader` if `hdu` is not a 3D cube.
    public static func collapsed(hdu: FITSHDU, mode: CollapseMode) throws -> FITSImage {
        guard hdu.naxis == 3 else {
            throw FITSError.invalidHeader("collapse requires NAXIS=3 (got \(hdu.naxis))")
        }
        let axes = hdu.axes
        let w = axes[0], h = axes[1], depth = axes[2]
        let pixelCount = w * h

        switch mode {
        case .sum, .mean, .max:
            // Online accumulators: one float per pixel, processed plane-by-plane.
            // No `depth × W × H × 8` peak allocation; safe for 100-plane HD cubes.
            var accum = [Double](repeating: 0, count: pixelCount)
            var counts = [Int32](repeating: 0, count: pixelCount)
            // Seed `accum` to -inf for `.max` so the first sample wins.
            if mode == .max {
                for i in 0..<pixelCount { accum[i] = -.infinity }
            }
            for p in 0..<depth {
                let plane = try FITSImage(hdu: hdu, plane: p).physicalValues()
                for i in 0..<pixelCount {
                    let v = plane[i]
                    if v.isNaN { continue }
                    counts[i] &+= 1
                    switch mode {
                    case .sum, .mean: accum[i] += v
                    case .max:        if v > accum[i] { accum[i] = v }
                    case .median:     break
                    }
                }
            }
            var out = [Float](repeating: 0, count: pixelCount)
            for i in 0..<pixelCount {
                let n = Int(counts[i])
                if n == 0 { out[i] = .nan; continue }
                switch mode {
                case .sum:   out[i] = Float(accum[i])
                case .mean:  out[i] = Float(accum[i] / Double(n))
                case .max:   out[i] = Float(accum[i])
                case .median: break
                }
            }
            return .fromFloat32(pixels: out, width: w, height: h)

        case .median:
            // Median needs every value per pixel; tile output so we hold at most
            // `tile × depth × 8` bytes of plane buffers at once. Tile chosen so
            // a 100-plane cube uses ≤ ~50 MB peak (≈ 64k pixels × 100 × 8 B).
            let tileSize = max(1, 65_536 / max(1, depth))
            var out = [Float](repeating: 0, count: pixelCount)
            var i = 0
            var perPixel = [Double](repeating: 0, count: tileSize * depth)
            while i < pixelCount {
                let take = min(tileSize, pixelCount - i)
                for p in 0..<depth {
                    let plane = try FITSImage(hdu: hdu, plane: p).physicalValues()
                    for k in 0..<take {
                        perPixel[k * depth + p] = plane[i + k]
                    }
                }
                for k in 0..<take {
                    var values: [Double] = []
                    values.reserveCapacity(depth)
                    for p in 0..<depth {
                        let v = perPixel[k * depth + p]
                        if !v.isNaN { values.append(v) }
                    }
                    if values.isEmpty { out[i + k] = .nan; continue }
                    values.sort()
                    let n = values.count
                    if n % 2 == 1 { out[i + k] = Float(values[n / 2]) }
                    else { out[i + k] = Float((values[n / 2 - 1] + values[n / 2]) / 2) }
                }
                i += take
            }
            return .fromFloat32(pixels: out, width: w, height: h)
        }
    }

    private func rawValue(x: Int, y: Int) -> Double {
        let idx = y * width + x
        switch pixelType {
        case .uint8:
            return Double(pixels[pixels.startIndex + idx])
        case .int16:
            let off = pixels.startIndex + idx * 2
            let hi = UInt16(pixels[off])
            let lo = UInt16(pixels[off + 1])
            let raw = Int16(bitPattern: (hi << 8) | lo)
            return Double(raw)
        case .int32:
            let off = pixels.startIndex + idx * 4
            let b0 = UInt32(pixels[off])
            let b1 = UInt32(pixels[off + 1])
            let b2 = UInt32(pixels[off + 2])
            let b3 = UInt32(pixels[off + 3])
            let bits = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            return Double(Int32(bitPattern: bits))
        case .float32:
            let off = pixels.startIndex + idx * 4
            let b0 = UInt32(pixels[off])
            let b1 = UInt32(pixels[off + 1])
            let b2 = UInt32(pixels[off + 2])
            let b3 = UInt32(pixels[off + 3])
            let bits = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            return Double(Float(bitPattern: bits))
        case .float64:
            let off = pixels.startIndex + idx * 8
            var bits: UInt64 = 0
            for i in 0..<8 {
                bits = (bits << 8) | UInt64(pixels[off + i])
            }
            return Double(bitPattern: bits)
        }
    }
}
