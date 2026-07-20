import XCTest
@testable import FITSCore

final class ProfilesTests: XCTestCase {
    // MARK: - Line profile

    func testLineProfileAlongHorizontalEdge() {
        // 5×3 image with values [1,2,3,4,5] in bottom row.
        var pix = [Float](repeating: 0, count: 15)
        for i in 0..<5 { pix[i] = Float(i + 1) }
        let img = FITSImage.fromFloat32(pixels: pix, width: 5, height: 3)
        let samples = Profiles.lineProfile(image: img, from: (0, 0), to: (4, 0), samples: 5)
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[0].value, 1, accuracy: 1e-6)
        XCTAssertEqual(samples[2].value, 3, accuracy: 1e-6)
        XCTAssertEqual(samples[4].value, 5, accuracy: 1e-6)
        // Distance accumulates pixel-by-pixel.
        XCTAssertEqual(samples[0].distance, 0, accuracy: 1e-6)
        XCTAssertEqual(samples[4].distance, 4, accuracy: 1e-6)
    }

    func testLineProfileBilinearInterpolatesBetweenPixels() {
        // 2×1 image with values [0, 10]. Bilinear at x=0.5 → 5.
        let img = FITSImage.fromFloat32(pixels: [0, 10], width: 2, height: 1)
        let samples = Profiles.lineProfile(image: img, from: (0, 0), to: (1, 0), samples: 3,
                                           interpolation: .bilinear)
        XCTAssertEqual(samples[0].value, 0, accuracy: 1e-6)
        XCTAssertEqual(samples[1].value, 5, accuracy: 1e-6)
        XCTAssertEqual(samples[2].value, 10, accuracy: 1e-6)
    }

    func testLineProfileNearestNeighbourDefault() {
        let img = FITSImage.fromFloat32(pixels: [0, 10], width: 2, height: 1)
        let samples = Profiles.lineProfile(image: img, from: (0, 0), to: (1, 0), samples: 3)
        // x=0.5 rounds to 1 → 10.
        XCTAssertEqual(samples[1].value, 10, accuracy: 1e-6)
    }

    func testLineProfileSamplesAreEquallySpaced() {
        let img = FITSImage.fromFloat32(pixels: [Float](repeating: 0, count: 100), width: 10, height: 10)
        let n = 8
        let samples = Profiles.lineProfile(image: img, from: (0, 0), to: (9, 0), samples: n)
        XCTAssertEqual(samples.count, n)
        for i in 1..<n {
            let step = samples[i].distance - samples[i - 1].distance
            XCTAssertEqual(step, 9.0 / Double(n - 1), accuracy: 1e-6)
        }
    }

    func testLineProfileOutOfBoundsValuesAreNaN() {
        let img = FITSImage.fromFloat32(pixels: [Float](repeating: 1, count: 4), width: 2, height: 2)
        let samples = Profiles.lineProfile(image: img, from: (-1, -1), to: (5, 5), samples: 5)
        // Most samples land outside image and should be NaN.
        let outsideCount = samples.filter { $0.value.isNaN }.count
        XCTAssertGreaterThan(outsideCount, 0)
    }

    // MARK: - Radial profile

    func testRadialProfileGaussianMonotonicallyDecreases() {
        // Synthetic isotropic Gaussian σ=2 centered at (10, 10).
        let w = 21, h = 21
        var pix = [Float](repeating: 0, count: w * h)
        let sigma = 2.0
        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x - 10), dy = Double(y - 10)
                pix[y * w + x] = Float(exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
            }
        }
        let img = FITSImage.fromFloat32(pixels: pix, width: w, height: h)
        let bins = Profiles.radialProfile(image: img, center: (10, 10), maxRadius: 8, binWidth: 1)
        XCTAssertGreaterThanOrEqual(bins.count, 5)
        // Each successive bin's mean ≤ previous (monotonically decreasing Gaussian).
        for i in 1..<bins.count {
            XCTAssertLessThanOrEqual(bins[i].mean, bins[i - 1].mean + 1e-9)
        }
        XCTAssertEqual(bins[0].mean, 1, accuracy: 0.05)
    }

    func testRadialProfileBinDistancesAreCentered() {
        let img = FITSImage.fromFloat32(pixels: [Float](repeating: 1, count: 49), width: 7, height: 7)
        let bins = Profiles.radialProfile(image: img, center: (3, 3), maxRadius: 3, binWidth: 1)
        // Bins centred at radius 0.5, 1.5, 2.5.
        XCTAssertEqual(bins[0].radius, 0.5, accuracy: 1e-6)
        XCTAssertEqual(bins[1].radius, 1.5, accuracy: 1e-6)
        XCTAssertEqual(bins[2].radius, 2.5, accuracy: 1e-6)
        // All means = 1 in uniform image.
        for b in bins { XCTAssertEqual(b.mean, 1, accuracy: 1e-6) }
    }

    // MARK: - Growth curve

    func testGrowthCurveIsMonotonicallyIncreasing() {
        // 21×21 Gaussian σ=2, total flux ≈ 1 (volume) up to radius extending the image.
        let w = 21, h = 21
        var pix = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x - 10), dy = Double(y - 10)
                pix[y * w + x] = Float(exp(-(dx * dx + dy * dy) / 8))
            }
        }
        let img = FITSImage.fromFloat32(pixels: pix, width: w, height: h)
        let curve = Profiles.growthCurve(image: img, center: (10, 10), maxRadius: 10, step: 1)
        XCTAssertGreaterThan(curve.count, 5)
        for i in 1..<curve.count {
            XCTAssertGreaterThanOrEqual(curve[i].cumulativeFlux, curve[i - 1].cumulativeFlux - 1e-9)
        }
        // Final cumulative ≈ Gaussian volume = 2π σ² = 2π·4 ≈ 25.13.
        XCTAssertEqual(curve.last!.cumulativeFlux, 2 * .pi * 4, accuracy: 0.5)
    }

    func testGrowthCurveFinalRadiusAtMax() {
        let img = FITSImage.fromFloat32(pixels: [Float](repeating: 1, count: 121), width: 11, height: 11)
        let curve = Profiles.growthCurve(image: img, center: (5, 5), maxRadius: 4, step: 1)
        XCTAssertEqual(curve.last!.radius, 4, accuracy: 1e-9)
    }

    // MARK: - Cube spectrum

    func testCubeSpectrumAtPixel() throws {
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                  -32"),
            pad("NAXIS   =                    3"),
            pad("NAXIS1  =                    2"),
            pad("NAXIS2  =                    2"),
            pad("NAXIS3  =                    4"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        var data = Data(header.utf8)
        for plane in 0..<4 {
            for cell in 0..<4 {
                let v = Float(plane * 10 + cell)
                let bits = v.bitPattern.bigEndian
                withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
            }
        }
        if data.count % 2880 != 0 {
            data.append(Data(repeating: 0, count: 2880 - data.count % 2880))
        }
        let hdu = try FITSFile(data: data).hdus[0]
        // Pixel (0, 0) of the cube: cell 0 in each plane → values 0, 10, 20, 30.
        let spec = try Profiles.cubeSpectrum(hdu: hdu, atPixel: (0, 0))
        XCTAssertEqual(spec, [0, 10, 20, 30])
    }

    func testPVDiagramShapeAndContent() throws {
        // 4×4×3 cube. plane k, pixel (x, y) → value = k * 100 + y * 10 + x
        let cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                  -32"),
            pad("NAXIS   =                    3"),
            pad("NAXIS1  =                    4"),
            pad("NAXIS2  =                    4"),
            pad("NAXIS3  =                    3"),
            pad("END"),
        ]
        var header = cards.joined()
        if header.count % 2880 != 0 {
            header += String(repeating: " ", count: 2880 - header.count % 2880)
        }
        var data = Data(header.utf8)
        for plane in 0..<3 {
            for y in 0..<4 {
                for x in 0..<4 {
                    let v = Float(plane * 100 + y * 10 + x)
                    let bits = v.bitPattern.bigEndian
                    withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
                }
            }
        }
        if data.count % 2880 != 0 {
            data.append(Data(repeating: 0, count: 2880 - data.count % 2880))
        }
        let hdu = try FITSFile(data: data).hdus[0]
        // Line from (0, 0) to (3, 0), 4 samples → traverses x=0..3 along row 0.
        let pv = try Profiles.pvDiagram(hdu: hdu, from: (0, 0), to: (3, 0), samples: 4)
        XCTAssertEqual(pv.width, 4)
        XCTAssertEqual(pv.height, 3)  // 3 planes
        // Bottom row (plane 0): values 0, 1, 2, 3.
        XCTAssertEqual(pv.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(pv.physicalValue(x: 3, y: 0), 3)
        // Top row (plane 2): 200, 201, 202, 203.
        XCTAssertEqual(pv.physicalValue(x: 0, y: 2), 200)
        XCTAssertEqual(pv.physicalValue(x: 3, y: 2), 203)
    }

    private func pad(_ s: String) -> String {
        s.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
