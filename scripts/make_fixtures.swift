#!/usr/bin/env swift
// Regenerates the three fixture FITS files under Tests/FITSCoreTests/Fixtures/.
// Run with: swift scripts/make_fixtures.swift
import Foundation

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/FITSCoreTests/Fixtures")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let blockSize = 2880

func pad80(_ s: String) -> String {
    s.padding(toLength: 80, withPad: " ", startingAt: 0)
}

func padToBlock(_ data: Data) -> Data {
    var out = data
    let r = out.count % blockSize
    if r != 0 { out.append(Data(repeating: 0, count: blockSize - r)) }
    return out
}

func headerBlock(_ cards: [String]) -> Data {
    var s = cards.map(pad80).joined()
    let r = s.count % blockSize
    if r != 0 { s += String(repeating: " ", count: blockSize - r) }
    return Data(s.utf8)
}

// MARK: - uint8_simple.fits — 16x16 ramp 0..255

do {
    var pixels = [UInt8]()
    for y in 0..<16 {
        for x in 0..<16 {
            pixels.append(UInt8((x + y * 16) % 256))
        }
    }
    let header = headerBlock([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                   16",
        "NAXIS2  =                   16",
        "OBJECT  = 'uint8 ramp fixture' ",
        "END",
    ])
    var out = header
    out.append(Data(pixels))
    out = padToBlock(out)
    try out.write(to: outDir.appendingPathComponent("uint8_simple.fits"))
}

// MARK: - float32_bscale.fits — 32x32 Gaussian, BSCALE=2.0, BZERO=10.0

do {
    let w = 32, h = 32
    let cx = Float(w) / 2, cy = Float(h) / 2
    let sigma2: Float = 36
    let header = headerBlock([
        "SIMPLE  =                    T",
        "BITPIX  =                  -32",
        "NAXIS   =                    2",
        "NAXIS1  = \(String(format: "%20d", w))",
        "NAXIS2  = \(String(format: "%20d", h))",
        "BSCALE  =                  2.0",
        "BZERO   =                 10.0",
        "OBJECT  = 'float32 Gaussian'   ",
        "END",
    ])
    var out = header
    for y in 0..<h {
        for x in 0..<w {
            let dx = Float(x) - cx
            let dy = Float(y) - cy
            let g = 500 * expf(-(dx*dx + dy*dy) / (2 * sigma2))
            var bits = g.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        }
    }
    out = padToBlock(out)
    try out.write(to: outDir.appendingPathComponent("float32_bscale.fits"))
}

// MARK: - multi_hdu.fits — primary HDU (NAXIS=0) + image extension (8x8 uint8)

do {
    let primary = headerBlock([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "EXTEND  =                    T",
        "END",
    ])
    let extHeader = headerBlock([
        "XTENSION= 'IMAGE   '           ",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    8",
        "NAXIS2  =                    8",
        "PCOUNT  =                    0",
        "GCOUNT  =                    1",
        "EXTNAME = 'SCI     '           ",
        "END",
    ])
    var extPixels = [UInt8]()
    for i in 0..<64 { extPixels.append(UInt8(i)) }
    var out = primary
    out.append(extHeader)
    out.append(Data(extPixels))
    out = padToBlock(out)
    try out.write(to: outDir.appendingPathComponent("multi_hdu.fits"))
}

print("Wrote fixtures to \(outDir.path)")
