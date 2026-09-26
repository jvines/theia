import Foundation
import CZlib

public enum RasterEncodingError: Error {
    case invalidDimensions
    case compressionFailed(Int32)
}

/// Portable PNG and baseline TIFF encoders for top-down RGBA8 rasters.
public enum RasterEncoder {
    public static func png(_ raster: RasterImage) throws -> Data {
        try validate(raster)
        var raw = [UInt8]()
        raw.reserveCapacity(raster.bytes.count + raster.height)
        for row in 0..<raster.height {
            raw.append(0) // PNG filter: None
            let start = row * raster.width * 4
            raw.append(contentsOf: raster.bytes[start..<(start + raster.width * 4)])
        }
        var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(raw.count))))
        var compressedLength = uLongf(compressed.count)
        let status = raw.withUnsafeBufferPointer { source in
            compressed.withUnsafeMutableBufferPointer { destination in
                compress2(destination.baseAddress, &compressedLength,
                          source.baseAddress, uLong(source.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw RasterEncodingError.compressionFailed(status) }
        compressed.removeLast(compressed.count - Int(compressedLength))

        var result = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var header = Data()
        header.appendBE(UInt32(raster.width))
        header.appendBE(UInt32(raster.height))
        header.append(contentsOf: [8, 6, 0, 0, 0]) // RGBA8, deflate, no interlace
        try result.appendPNGChunk("IHDR", payload: header)
        try result.appendPNGChunk("IDAT", payload: Data(compressed))
        try result.appendPNGChunk("IEND", payload: Data())
        return result
    }

    public static func tiff(_ raster: RasterImage) throws -> Data {
        try validate(raster)
        let tagCount = 11
        let bitsOffset = 8 + 2 + tagCount * 12 + 4
        let pixelsOffset = bitsOffset + 8
        guard pixelsOffset + raster.bytes.count <= Int(UInt32.max) else {
            throw RasterEncodingError.invalidDimensions
        }

        var result = Data([73, 73, 42, 0]) // little-endian TIFF
        result.appendLE(UInt32(8)) // first IFD
        result.appendLE(UInt16(tagCount))
        func tag(_ id: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            result.appendLE(id)
            result.appendLE(type)
            result.appendLE(count)
            result.appendLE(value)
        }
        tag(256, 4, 1, UInt32(raster.width))   // ImageWidth
        tag(257, 4, 1, UInt32(raster.height))  // ImageLength
        tag(258, 3, 4, UInt32(bitsOffset))     // BitsPerSample
        tag(259, 3, 1, 1)                      // Compression: none
        tag(262, 3, 1, 2)                      // Photometric: RGB
        tag(273, 4, 1, UInt32(pixelsOffset))   // StripOffsets
        tag(277, 3, 1, 4)                      // SamplesPerPixel
        tag(278, 4, 1, UInt32(raster.height))  // RowsPerStrip
        tag(279, 4, 1, UInt32(raster.bytes.count)) // StripByteCounts
        tag(284, 3, 1, 1)                      // PlanarConfiguration: chunky
        tag(338, 3, 1, 2)                      // ExtraSamples: straight alpha
        result.appendLE(UInt32(0)) // no next IFD
        for _ in 0..<4 { result.appendLE(UInt16(8)) }
        result.append(contentsOf: raster.bytes)
        return result
    }

    private static func validate(_ raster: RasterImage) throws {
        guard raster.width > 0, raster.height > 0,
              raster.width <= Int(UInt32.max), raster.height <= Int(UInt32.max),
              raster.width <= Int.max / 4 / raster.height,
              raster.bytes.count == raster.width * raster.height * 4 else {
            throw RasterEncodingError.invalidDimensions
        }
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255),
                            UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    mutating func appendLE(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)])
    }

    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255),
                            UInt8((value >> 16) & 255), UInt8(value >> 24)])
    }

    mutating func appendPNGChunk(_ type: String, payload: Data) throws {
        guard payload.count <= Int(UInt32.max) else { throw RasterEncodingError.invalidDimensions }
        let body = Data(type.utf8) + payload
        appendBE(UInt32(payload.count))
        append(body)
        let checksum = body.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(body.count))
        }
        appendBE(UInt32(checksum))
    }
}
