import CGtk4
import FITSRaster
import XCTest
@testable import TheiaGTK

final class GTKCanvasTextureTests: XCTestCase {
    func testRGBAByteOrderSurvivesGDKTextureDownload() {
        let pixels: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
        ]
        let prepared = GTKCanvasTexture.prepare(
            from: RasterImage(width: 3, height: 1, bytes: pixels)
        )
        let texture = GTKCanvasTexture.make(from: prepared)
        defer { g_object_unref(UnsafeMutableRawPointer(texture)) }

        XCTAssertEqual(gdk_texture_get_width(texture), 3)
        XCTAssertEqual(gdk_texture_get_height(texture), 1)
        var downloaded = [UInt8](repeating: 0, count: pixels.count)
        downloaded.withUnsafeMutableBufferPointer { buffer in
            gdk_texture_download(texture, buffer.baseAddress, 12)
        }
        // GdkTexture.download returns native little-endian Cairo ARGB32 (BGRA).
        XCTAssertEqual(downloaded, [
            0, 0, 255, 255,
            0, 255, 0, 255,
            255, 0, 0, 255,
        ])
    }
}
