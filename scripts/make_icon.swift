#!/usr/bin/env swift
// Generates AppIcon.iconset/ with PNGs at all macOS app-icon sizes.
// Run scripts/make_icon.sh to produce the final AppIcon.icns.
//
// Design: deep-navy squircle background with a faint pixel-grid texture, a green
// photometry aperture (open ring) centred on a golden star with 4 diffraction
// spikes. Reads cleanly from 16 px up to 1024 px.

import Foundation
import AppKit
import CoreGraphics

let sizes: [(label: String, size: Int)] = [
    ("16x16",       16),
    ("16x16@2x",    32),
    ("32x32",       32),
    ("32x32@2x",    64),
    ("128x128",    128),
    ("128x128@2x", 256),
    ("256x256",    256),
    ("256x256@2x", 512),
    ("512x512",    512),
    ("512x512@2x",1024),
]

let outDir = URL(fileURLWithPath: "dist/AppIcon.iconset")
try? FileManager.default.removeItem(at: outDir)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func makePNG(size px: Int) -> Data? {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: px, height: px,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Coordinates use px as the unit.
    let rect = CGRect(x: 0, y: 0, width: px, height: px)
    let p = Double(px)

    // -- Background squircle (rounded rect) ---------------------------------
    let cornerRadius = p * 0.225   // Apple's macOS app icon "superellipse" approximation
    let inset = p * 0.105          // leave Apple's safe-area padding
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // Gradient deep-navy → almost-black
    let colors = [
        CGColor(srgbRed: 0.06, green: 0.09, blue: 0.18, alpha: 1),  // deep navy
        CGColor(srgbRed: 0.02, green: 0.03, blue: 0.07, alpha: 1),  // near black
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: bgRect.maxY),
                               end:   CGPoint(x: 0, y: bgRect.minY),
                               options: [])
    }

    // -- Subtle pixel-grid texture -------------------------------------------
    if px >= 64 {
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.04))
        ctx.setLineWidth(max(0.5, p * 0.0015))
        let step = max(8.0, p * 0.05)
        var x = bgRect.minX
        while x <= bgRect.maxX {
            ctx.move(to: CGPoint(x: x, y: bgRect.minY))
            ctx.addLine(to: CGPoint(x: x, y: bgRect.maxY))
            x += step
        }
        var y = bgRect.minY
        while y <= bgRect.maxY {
            ctx.move(to: CGPoint(x: bgRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: bgRect.maxX, y: y))
            y += step
        }
        ctx.strokePath()
    }

    // -- Sprinkle of faint background stars ----------------------------------
    if px >= 128 {
        var seed: UInt64 = 0x91827364
        func nextRand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(UInt64.max >> 33)
        }
        let n = max(8, Int(p / 32))
        for _ in 0..<n {
            let cx = bgRect.minX + bgRect.width * nextRand()
            let cy = bgRect.minY + bgRect.height * nextRand()
            let r = p * (0.003 + 0.006 * nextRand())
            let alpha = 0.25 + 0.55 * nextRand()
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }
    }

    // -- Star glow + core + diffraction spikes -------------------------------
    let cx = rect.midX
    let cy = rect.midY

    // Wide soft glow.
    let glowR = p * 0.18
    let glowColors = [
        CGColor(srgbRed: 1.0, green: 0.92, blue: 0.55, alpha: 0.55),
        CGColor(srgbRed: 1.0, green: 0.85, blue: 0.35, alpha: 0.0),
    ] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: glowColors, locations: [0, 1]) {
        ctx.drawRadialGradient(
            g,
            startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
            endCenter:   CGPoint(x: cx, y: cy), endRadius: glowR,
            options: []
        )
    }

    // Diffraction spikes (4-prong cross).
    let spikeLen = p * 0.30
    let spikeWidthMax = max(1.0, p * 0.012)
    let spikeColors = [
        CGColor(srgbRed: 1.0, green: 0.95, blue: 0.7, alpha: 0.9),
        CGColor(srgbRed: 1.0, green: 0.95, blue: 0.7, alpha: 0.0),
    ] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: spikeColors, locations: [0, 1]) {
        for angleDeg in stride(from: 0.0, to: 180.0, by: 90.0) {
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: CGFloat(angleDeg * .pi / 180))
            // Draw two opposite rays.
            for direction in [1.0, -1.0] {
                ctx.saveGState()
                ctx.scaleBy(x: 1, y: CGFloat(direction))
                // Approximate a fading line by stroking many segments with a gradient
                // along its length.
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: spikeLen))
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineCap(.round)
                ctx.setLineWidth(spikeWidthMax)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                ctx.drawLinearGradient(g,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: spikeLen),
                                       options: [])
                ctx.restoreGState()
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
    }

    // Bright star core.
    let coreR = p * 0.040
    let coreColors = [
        CGColor(srgbRed: 1.0, green: 1.0, blue: 0.96, alpha: 1),
        CGColor(srgbRed: 1.0, green: 0.85, blue: 0.30, alpha: 0.0),
    ] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: coreColors, locations: [0, 1]) {
        ctx.drawRadialGradient(
            g,
            startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
            endCenter:   CGPoint(x: cx, y: cy), endRadius: coreR * 4,
            options: []
        )
    }

    // -- Photometry aperture (open green ring) -------------------------------
    let apertureR = p * 0.34
    let apertureLine = max(2.0, p * 0.022)
    ctx.setStrokeColor(CGColor(srgbRed: 0.40, green: 0.95, blue: 0.55, alpha: 0.85))
    ctx.setLineWidth(apertureLine)
    ctx.strokeEllipse(in: CGRect(x: cx - apertureR, y: cy - apertureR,
                                 width: apertureR * 2, height: apertureR * 2))
    // Tiny tick marks (compass-style at 0/90/180/270) so it reads as a tool.
    if px >= 128 {
        let tickLen = apertureR * 0.18
        ctx.setLineWidth(max(1.5, p * 0.012))
        for angleDeg in stride(from: 0.0, to: 360.0, by: 90.0) {
            let a = angleDeg * .pi / 180
            let inner = apertureR + apertureLine * 0.5
            let outer = inner + tickLen
            ctx.move(to: CGPoint(x: cx + CGFloat(cos(a)) * inner, y: cy + CGFloat(sin(a)) * inner))
            ctx.addLine(to: CGPoint(x: cx + CGFloat(cos(a)) * outer, y: cy + CGFloat(sin(a)) * outer))
        }
        ctx.strokePath()
    }

    // -- Encode PNG ----------------------------------------------------------
    guard let cg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])
}

for entry in sizes {
    guard let data = makePNG(size: entry.size) else {
        print("error: failed to generate \(entry.label)")
        exit(1)
    }
    let url = outDir.appendingPathComponent("icon_\(entry.label).png")
    try data.write(to: url)
    print("wrote \(url.path) (\(entry.size)px, \(data.count) bytes)")
}
