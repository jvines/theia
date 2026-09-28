import CGtk4
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKOverlayPainterTests: XCTestCase {
    func testDrawsSharedPrimitivesIntoTransparentCairoSurface() throws {
        let surface = try XCTUnwrap(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 48, 48))
        defer { cairo_surface_destroy(surface) }
        let context = try XCTUnwrap(cairo_create(surface))
        defer { cairo_destroy(context) }

        GTKOverlayPainter.draw([
            .segments([.init(from: SIMD2(4, 8), to: SIMD2(44, 8))],
                      stroke: .init(red: 1, green: 0, blue: 0), opacity: 1,
                      lineWidth: 3, dash: []),
            .path(points: [SIMD2(4, 16), SIMD2(44, 16)], closed: false,
                  stroke: .init(red: 0, green: 1, blue: 0), opacity: 1,
                  lineWidth: 3),
            .ellipse(center: SIMD2(24, 30), radiusX: 10, radiusY: 6,
                     stroke: .init(red: 0, green: 0, blue: 1), opacity: 1,
                     lineWidth: 3),
            .handle(center: SIMD2(24, 30), radius: 3,
                    color: .init(red: 1, green: 1, blue: 0)),
        ], in: context)
        cairo_surface_flush(surface)

        let pixels = try XCTUnwrap(cairo_image_surface_get_data(surface))
        let stride = Int(cairo_image_surface_get_stride(surface))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[y * stride + x * 4 + 3] }
        XCTAssertEqual(alpha(0, 0), 0)
        XCTAssertGreaterThan(alpha(24, 8), 0)
        XCTAssertGreaterThan(alpha(24, 16), 0)
        XCTAssertGreaterThan(alpha(24, 24), 0)
        XCTAssertGreaterThan(alpha(24, 30), 0)
    }
}
