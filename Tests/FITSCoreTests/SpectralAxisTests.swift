import XCTest
@testable import FITSCore

final class SpectralAxisTests: XCTestCase {
    private func pad(_ s: String) -> String { s.padding(toLength: 80, withPad: " ", startingAt: 0) }

    private func makeHeader(_ extra: [String]) throws -> FITSHeader {
        var cards = [
            pad("SIMPLE  =                    T"),
            pad("BITPIX  =                    8"),
            pad("NAXIS   =                    0"),
        ]
        cards.append(contentsOf: extra.map { pad($0) })
        cards.append(pad("END"))
        var h = cards.joined()
        if h.count % 2880 != 0 { h += String(repeating: " ", count: 2880 - h.count % 2880) }
        return try FITSFile(data: Data(h.utf8)).hdus[0].header
    }

    func testWavelengthAxisLinear() throws {
        // crval=5000Å at crpix=1, cdelt=10 Å/plane → planes 0..3 map to 5000, 5010, 5020, 5030
        let hdr = try makeHeader([
            "CRVAL3  =              5000.0",
            "CRPIX3  =                 1.0",
            "CDELT3  =                10.0",
            "CTYPE3  = 'WAVE'              ",
            "CUNIT3  = 'Angstrom'          ",
        ])
        let s = SpectralAxis(header: hdr)!
        XCTAssertEqual(s.value(forPlane: 0), 5000, accuracy: 1e-9)
        XCTAssertEqual(s.value(forPlane: 1), 5010, accuracy: 1e-9)
        XCTAssertEqual(s.value(forPlane: 3), 5030, accuracy: 1e-9)
        XCTAssertEqual(s.axisLabel, "wavelength [Angstrom]")
    }

    func testReturnsNilWithoutCRVAL3() throws {
        let hdr = try makeHeader([])
        XCTAssertNil(SpectralAxis(header: hdr))
    }

    func testFrequencyAxisLabel() throws {
        let hdr = try makeHeader([
            "CRVAL3  =                 1e9",
            "CDELT3  =                 1e6",
            "CTYPE3  = 'FREQ'              ",
            "CUNIT3  = 'Hz'                ",
        ])
        let s = SpectralAxis(header: hdr)!
        XCTAssertEqual(s.axisLabel, "frequency [Hz]")
    }

    func testCD3_3Fallback() throws {
        let hdr = try makeHeader([
            "CRVAL3  =                 0.0",
            "CD3_3   =                 5.0",
            "CTYPE3  = 'VOPT'              ",
            "CUNIT3  = 'm/s'               ",
        ])
        let s = SpectralAxis(header: hdr)!
        XCTAssertEqual(s.value(forPlane: 2), 10, accuracy: 1e-9)
        XCTAssertEqual(s.axisLabel, "velocity [m/s]")
    }
}
