import CFITSIO
import Foundation

public enum CFITSIOError: Error, CustomStringConvertible {
    case status(Int32, String)
    public var description: String {
        switch self { case let .status(code, msg): return "CFITSIO error \(code): \(msg)" }
    }
}

/// Thin Swift surface over the vendored CFITSIO library. CFITSIO transparently
/// decompresses tile-compressed (`.fz`) images on read, so this is the bridge the
/// `.fz` support is built on.
public enum CFITSIOLibrary {
    /// The linked CFITSIO version, e.g. `4.0604` for 4.6.4.
    public static var version: Float {
        var v: Float = 0
        _ = ffvers(&v)
        return v
    }

    private static func check(_ status: Int32) throws {
        guard status != 0 else { return }
        var buf = [CChar](repeating: 0, count: Int(FLEN_ERRMSG))
        ffgerr(status, &buf)
        throw CFITSIOError.status(status, String(cString: buf))
    }

    public struct DecodedImage: Sendable {
        public let width: Int
        public let height: Int
        /// Physical pixel values (BSCALE/BZERO applied), row-major, x fastest.
        public let pixels: [Double]
    }

    /// Opens `path`, moves to the first image HDU (tile-compressed images are
    /// transparently decompressed), and returns physical pixel values as Doubles.
    public static func readPhysicalImage(path: String) throws -> DecodedImage {
        var status: Int32 = 0
        var fptr: UnsafeMutablePointer<fitsfile>?
        _ = path.withCString { ffopen(&fptr, $0, READONLY, &status) }
        try check(status)
        defer { var s: Int32 = 0; ffclos(fptr, &s) }

        var nhdu: Int32 = 0
        ffthdu(fptr, &nhdu, &status)
        try check(status)

        for hdu in 1...max(nhdu, 1) {
            var hdutype: Int32 = 0
            ffmahd(fptr, hdu, &hdutype, &status)
            try check(status)
            var naxis: Int32 = 0
            ffgidm(fptr, &naxis, &status)
            try check(status)
            guard naxis >= 2 else { continue }

            var naxes = [Int](repeating: 0, count: Int(naxis))
            ffgisz(fptr, naxis, &naxes, &status)
            try check(status)
            let width = naxes[0]
            let height = naxes[1]
            let nelem = width * height
            var pixels = [Double](repeating: 0, count: nelem)
            var firstpix = [Int](repeating: 1, count: Int(naxis))
            var anynul: Int32 = 0
            pixels.withUnsafeMutableBufferPointer { pbuf in
                ffgpxv(fptr, TDOUBLE, &firstpix, LONGLONG(nelem), nil, pbuf.baseAddress, &anynul, &status)
            }
            try check(status)
            return DecodedImage(width: width, height: height, pixels: pixels)
        }
        throw CFITSIOError.status(-1, "no image HDU found in \(path)")
    }

    /// A tile-compressed image HDU decompressed into a native, uncompressed FITS
    /// representation: the equivalent `BITPIX`, the axis lengths, and the pixel
    /// data packed as big-endian bytes in that BITPIX (ready to drop into a
    /// `FITSHDU`). Stored as float32 unless the source needs the wider range of
    /// float64 (32/64-bit integer or float64 sources), which keeps integer data
    /// lossless. Physical scaling (BSCALE/BZERO) is already applied by CFITSIO.
    public struct NativeImage: Sendable {
        public let bitpix: Int
        public let axes: [Int]
        public let bigEndianData: Data
    }

    /// Decompresses the image at `hduIndex1Based` (1-based, CFITSIO numbering) from
    /// an in-memory FITS file. No temp files — reads straight from `fileData`.
    public static func decompressNativeImage(fileData: Data, hduIndex1Based: Int) throws -> NativeImage {
        try fileData.withUnsafeBytes { raw -> NativeImage in
            var status: Int32 = 0
            var fptr: UnsafeMutablePointer<fitsfile>?
            // READONLY: CFITSIO won't mutate or realloc, so handing it a mutating
            // view of the (immutable, possibly mmap-backed) bytes is safe.
            var bufPtr: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(mutating: raw.baseAddress)
            var bufSize = raw.count
            _ = "mem.fits".withCString { ffomem(&fptr, $0, READONLY, &bufPtr, &bufSize, 0, nil, &status) }
            try check(status)
            defer { var s: Int32 = 0; ffclos(fptr, &s) }

            var hdutype: Int32 = 0
            ffmahd(fptr, Int32(hduIndex1Based), &hdutype, &status)
            try check(status)
            var naxis: Int32 = 0
            ffgidm(fptr, &naxis, &status)
            try check(status)
            guard naxis >= 2 else {
                throw CFITSIOError.status(-1, "HDU \(hduIndex1Based) is not an image")
            }
            var naxes = [Int](repeating: 0, count: Int(naxis))
            ffgisz(fptr, naxis, &naxes, &status)
            try check(status)
            var equivtype: Int32 = 0
            ffgiet(fptr, &equivtype, &status)
            try check(status)

            let nelem = naxes.reduce(1, *)
            var dbl = [Double](repeating: 0, count: nelem)
            var firstpix = [Int](repeating: 1, count: Int(naxis))
            var anynul: Int32 = 0
            dbl.withUnsafeMutableBufferPointer { p in
                ffgpxv(fptr, TDOUBLE, &firstpix, LONGLONG(nelem), nil, p.baseAddress, &anynul, &status)
            }
            try check(status)

            // float32 is enough for 8/16-bit ints and float32 sources; use float64
            // for 32/64-bit ints and float64 to avoid silent precision loss.
            let needsDouble = (equivtype == 32 || equivtype == 64 || equivtype == -64)
            let bitpix = needsDouble ? -64 : -32
            let data: Data = needsDouble
                ? dbl.withUnsafeBufferPointer { src in
                    var be = [UInt64](repeating: 0, count: nelem)
                    for i in 0..<nelem { be[i] = src[i].bitPattern.bigEndian }
                    return be.withUnsafeBufferPointer { Data(buffer: $0) }
                }
                : dbl.withUnsafeBufferPointer { src in
                    var be = [UInt32](repeating: 0, count: nelem)
                    for i in 0..<nelem { be[i] = Float(src[i]).bitPattern.bigEndian }
                    return be.withUnsafeBufferPointer { Data(buffer: $0) }
                }
            return NativeImage(bitpix: bitpix, axes: naxes, bigEndianData: data)
        }
    }

    /// Writes a tile-compressed copy of `inputPath` to `outputPath` using the given
    /// CFITSIO compression directive letter (e.g. "R" Rice, "G" GZIP, "H" Hcompress).
    /// Utility/test support — overwrites `outputPath`.
    public static func writeCompressed(from inputPath: String, to outputPath: String, algorithm: String = "R") throws {
        var status: Int32 = 0
        var inp: UnsafeMutablePointer<fitsfile>?
        var out: UnsafeMutablePointer<fitsfile>?
        _ = inputPath.withCString { ffopen(&inp, $0, READONLY, &status) }
        try check(status)
        defer { var s: Int32 = 0; ffclos(inp, &s) }

        let spec = "!\(outputPath)[compress \(algorithm)]"
        _ = spec.withCString { ffinit(&out, $0, &status) }
        try check(status)
        ffcpfl(inp, out, 1, 1, 1, &status)
        var closeStatus: Int32 = 0
        ffclos(out, &closeStatus)
        try check(status)
    }
}
