import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class OverlaySceneCompassTests: XCTestCase {
    func testCompassAndScaleBarUseFixedViewPositionsAndAngularUnits() throws {
        let white = OverlayColor(red: 1, green: 1, blue: 1)
        let primitives = OverlayScene.compassAndScaleBar(
            wcs: try makeWCS(), viewSize: SIMD2(400, 200), viewportScale: 2
        )
        guard case .segments(let arrows, let arrowColor, let arrowOpacity, let arrowWidth, _) = primitives[0] else {
            return XCTFail("expected compass arrows")
        }
        XCTAssertEqual(arrows.count, 2)
        XCTAssertEqual(arrows[0].from, SIMD2(50, 50))
        XCTAssertEqual(arrows[0].to.x, 20, accuracy: 1e-9)
        XCTAssertEqual(arrows[0].to.y, 50, accuracy: 1e-9)
        XCTAssertEqual(arrows[1].to.x, 50, accuracy: 1e-9)
        XCTAssertEqual(arrows[1].to.y, 20, accuracy: 1e-9)
        XCTAssertEqual(arrowColor, white)
        XCTAssertEqual(arrowOpacity, 0.9)
        XCTAssertEqual(arrowWidth, 1.5)

        XCTAssertTrue(primitives.contains(.text("E", at: SIMD2(10, 50), color: white,
                                               size: 12, opacity: 1, font: .systemSemibold)))
        XCTAssertTrue(primitives.contains(.text("N", at: SIMD2(50, 10), color: white,
                                               size: 12, opacity: 1, font: .systemSemibold)))
        guard case .segments(let bar, _, _, _, _) = primitives[3] else {
            return XCTFail("expected scale bar")
        }
        XCTAssertEqual(bar.count, 3)
        XCTAssertEqual(bar[0].from, SIMD2(30, 170))
        XCTAssertEqual(bar[0].to.x, 130, accuracy: 0.001)
        XCTAssertEqual(bar[0].to.y, 170, accuracy: 1e-9)
        XCTAssertEqual(bar[1].from, SIMD2(30, 165))
        XCTAssertEqual(bar[2].to.y, 175)
        guard case .text(let label, let at, _, let size, _, let font, _, _) = primitives[4] else {
            return XCTFail("expected scale label")
        }
        XCTAssertEqual(label, "50″")
        XCTAssertEqual(at.x, 80, accuracy: 0.001)
        XCTAssertEqual(at.y, 156)
        XCTAssertEqual(size, 12)
        XCTAssertEqual(font, .systemMedium)
    }

    func testInvalidViewportScaleOmitsScaleBarButKeepsCompass() throws {
        let primitives = OverlayScene.compassAndScaleBar(
            wcs: try makeWCS(), viewSize: SIMD2(400, 200), viewportScale: 0
        )
        XCTAssertEqual(primitives.count, 3)
    }

    func testColorBarLabelsPreserveFiniteScientificAndMissingFormats() {
        XCTAssertEqual(OverlayScene.colorBarLabels(vmin: 0, vmax: 20_000),
                       .init(top: "2.00e+04", middle: "1.00e+04", bottom: "0"))
        XCTAssertEqual(OverlayScene.colorBarLabels(vmin: -.infinity, vmax: 0.005),
                       .init(top: "5.00e-03", middle: "—", bottom: "—"))
        XCTAssertEqual(OverlayScene.colorBarLabels(vmin: -3, vmax: 3),
                       .init(top: "3", middle: "0", bottom: "-3"))
    }

    func testGridPrimitivesMapCachedImageLinesAtCurrentViewScale() async throws {
        let wcs = try makeWCS()
        let lines = await MainActor.run {
            WCSGridCache().gridlines(wcs: wcs, imageWidth: 100, imageHeight: 100)
        }
        XCTAssertFalse(lines.isEmpty)
        let mapping = ViewMapping(transform: ViewTransform(scale: 2, centre: .zero),
                                  viewSize: SIMD2(200, 200), backingScale: 1)
        let primitives = OverlayScene.gridPrimitives(lines, mapping: mapping)
        XCTAssertEqual(primitives.count, lines.count)
        guard let firstLine = lines.first, let imagePoint = firstLine.pixelPoints.first,
              let firstPrimitive = primitives.first,
              case .path(let points, let closed, let color, let opacity, let width) = firstPrimitive,
              let viewPoint = points.first else { return XCTFail("expected first grid path") }
        XCTAssertEqual(viewPoint, mapping.imageToView(imagePoint))
        XCTAssertFalse(closed)
        XCTAssertEqual(color, firstLine.kind == .ra
                       ? OverlayColor(red: 0, green: 1, blue: 0)
                       : OverlayColor(red: 1, green: 1, blue: 0))
        XCTAssertEqual(opacity, 0.6)
        XCTAssertEqual(width, 0.7)
    }

    func testColorBarLabelsHavePortableTrailingAnchorsAndBackgrounds() {
        let labels = OverlayScene.colorBarLabelPrimitives(
            vmin: -3, vmax: 3, labelSize: SIMD2(70, 200)
        )
        XCTAssertEqual(labels.count, 3)
        guard case .text("3", let top, let topColor, let topSize, let topOpacity,
                         let topFont, let topAnchor, let topBackground) = labels[0],
              case .text("0", let middle, _, _, _, _, let middleAnchor, _) = labels[1],
              case .text("-3", let bottom, _, _, _, _, let bottomAnchor, _) = labels[2] else {
            return XCTFail("expected three color bar labels")
        }
        XCTAssertEqual(top, SIMD2(70, 0))
        XCTAssertEqual(middle, SIMD2(70, 100))
        XCTAssertEqual(bottom, SIMD2(70, 200))
        XCTAssertEqual(topColor, OverlayColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(topSize, 11)
        XCTAssertEqual(topOpacity, 1)
        XCTAssertEqual(topFont, .monospaced)
        XCTAssertEqual(topAnchor, .topTrailing)
        XCTAssertEqual(middleAnchor, .trailing)
        XCTAssertEqual(bottomAnchor, .bottomTrailing)
        XCTAssertEqual(topBackground, .init(color: .init(red: 0, green: 0, blue: 0),
                                            opacity: 0.55, cornerRadius: 3,
                                            horizontalPadding: 4, verticalPadding: 1))
    }

    private func makeWCS() throws -> WCS {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0",
            "CTYPE1  = 'RA---TAN'", "CTYPE2  = 'DEC--TAN'",
            "CRPIX1  =                 50.0", "CRPIX2  =                 50.0",
            "CRVAL1  =                180.0", "CRVAL2  =                  0.0",
            "CDELT1  =        -0.0002777778", "CDELT2  =         0.0002777778", "END",
        ]
        var text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        text += String(repeating: " ", count: (2880 - text.count % 2880) % 2880)
        return try XCTUnwrap(WCS(header: FITSFile(data: Data(text.utf8)).hdus[0].header))
    }
}
