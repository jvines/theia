#!/usr/bin/env swift
// Generates a deterministic 128×128×16 Float32 FITS cube with a moving source.
// Usage: swift scripts/make_sample_cube.swift > sample-cube.fits

import Foundation

let width = 128
let height = 128
let planes = 16
let blockSize = 2880

func card(_ text: String) -> String {
    text.padding(toLength: 80, withPad: " ", startingAt: 0)
}

let scale = 1.0 / 3600.0
let cards = [
    "SIMPLE  =                    T",
    "BITPIX  =                  -32",
    "NAXIS   =                    3",
    "NAXIS1  = \(String(format: "%20d", width))",
    "NAXIS2  = \(String(format: "%20d", height))",
    "NAXIS3  = \(String(format: "%20d", planes))",
    "OBJECT  = 'moving synthetic source'",
    "CTYPE1  = 'RA---TAN'",
    "CTYPE2  = 'DEC--TAN'",
    "CTYPE3  = 'VELO-LSR'",
    "CUNIT3  = 'm/s'",
    "CRPIX1  = \(String(format: "%20.6f", Double(width) / 2))",
    "CRPIX2  = \(String(format: "%20.6f", Double(height) / 2))",
    "CRPIX3  =                  1.0",
    "CRVAL1  =                180.0",
    "CRVAL2  =                  0.0",
    "CRVAL3  =              -7500.0",
    "CD1_1   = \(String(format: "%20.10f", -scale))",
    "CD1_2   =                  0.0",
    "CD2_1   =                  0.0",
    "CD2_2   = \(String(format: "%20.10f", scale))",
    "CDELT3  =               1000.0",
    "END",
]
var header = cards.map(card).joined()
header += String(repeating: " ", count: (blockSize - header.utf8.count % blockSize) % blockSize)

var output = Data(header.utf8)
output.reserveCapacity(output.count + width * height * planes * MemoryLayout<Float>.size + blockSize)
for plane in 0..<planes {
    let offset = Float(plane) - 7.5
    let amplitude = 100 + 500 * expf(-(offset * offset) / 18)
    let centerX = Float(36 + 3 * plane)
    for y in 0..<height {
        for x in 0..<width {
            let dx = Float(x) - centerX
            let dy = Float(y) - 64
            let pixel = 5 + amplitude * expf(-(dx * dx + dy * dy) / 242)
            var bits = pixel.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { output.append(contentsOf: $0) }
        }
    }
}
output.append(Data(repeating: 0, count: (blockSize - output.count % blockSize) % blockSize))
FileHandle.standardOutput.write(output)
