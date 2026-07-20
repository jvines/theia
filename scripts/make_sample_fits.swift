#!/usr/bin/env swift
// Generates a synthetic 200×200 Float32 FITS image of a Gaussian PSF + noise.
// Usage: swift scripts/make_sample_fits.swift > sample.fits

import Foundation

let w = 200, h = 200
let cx = Float(w) / 2, cy = Float(h) / 2
let sigma2: Float = 400  // sigma ≈ 20 px
var pixels = [Float](repeating: 0, count: w * h)
for y in 0..<h {
    for x in 0..<w {
        let dx = Float(x) - cx
        let dy = Float(y) - cy
        let g = 1000 * expf(-(dx*dx + dy*dy) / (2 * sigma2))
        let noise = Float.random(in: -5...5)
        pixels[y * w + x] = g + noise
    }
}

func pad80(_ s: String) -> String {
    s.padding(toLength: 80, withPad: " ", startingAt: 0)
}

// WCS: gnomonic TAN, centred on (RA, Dec) = (180°, 0°), 1 arcsec/pixel,
// reference pixel at the image centre.
let cdScale = 1.0 / 3600   // 1 arcsec/pixel in degrees
let cards: [String] = [
    "SIMPLE  =                    T",
    "BITPIX  =                  -32",
    "NAXIS   =                    2",
    "NAXIS1  = \(String(format: "%20d", w))",
    "NAXIS2  = \(String(format: "%20d", h))",
    "OBJECT  = 'synthetic Gaussian' ",
    "CTYPE1  = 'RA---TAN'           ",
    "CTYPE2  = 'DEC--TAN'           ",
    "CRPIX1  = \(String(format: "%20.6f", Double(w) / 2))",
    "CRPIX2  = \(String(format: "%20.6f", Double(h) / 2))",
    "CRVAL1  = \(String(format: "%20.6f", 180.0))",
    "CRVAL2  = \(String(format: "%20.6f", 0.0))",
    "CD1_1   = \(String(format: "%20.10f", -cdScale))",
    "CD1_2   = \(String(format: "%20.10f", 0.0))",
    "CD2_1   = \(String(format: "%20.10f", 0.0))",
    "CD2_2   = \(String(format: "%20.10f", cdScale))",
    "END",
].map(pad80)

var header = cards.joined()
let blockSize = 2880
if header.count % blockSize != 0 {
    header += String(repeating: " ", count: blockSize - header.count % blockSize)
}

var out = Data(header.utf8)
for pixel in pixels {
    var bits = pixel.bitPattern.bigEndian
    withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
}
let pixelBytes = pixels.count * MemoryLayout<Float>.size
let dataPad = pixelBytes % blockSize == 0 ? 0 : blockSize - pixelBytes % blockSize
if dataPad > 0 { out.append(Data(repeating: 0, count: dataPad)) }

FileHandle.standardOutput.write(out)
