import XCTest
@testable import FITSCore

final class RegionFileTests: XCTestCase {
    func testParsesFK5FrameAndArcsecRadius() throws {
        let text = """
        fk5
        circle(180.0, 0.0, 5")
        """
        let r = try RegionFile.parse(text)[0]
        XCTAssertEqual(r.frame, .fk5)
        XCTAssertEqual(r.shape, .circle(
            center: .init(x: 180, y: 0),
            radius: .init(value: 5, unit: .arcsecond)
        ))
    }

    func testParsesBoxWithAngleAndArcminDimensions() throws {
        let text = "image\nbox(100, 200, 30', 20', 45)"
        let r = try RegionFile.parse(text)[0]
        XCTAssertEqual(r.shape, .box(
            center: .init(x: 100, y: 200),
            width: .init(value: 30, unit: .arcminute),
            height: .init(value: 20, unit: .arcminute),
            angle: 45
        ))
    }

    func testParsesPolygon() throws {
        let r = try RegionFile.parse("image\npolygon(10, 20, 11, 21, 12, 20)")[0]
        XCTAssertEqual(r.shape, .polygon(points: [
            .init(x: 10, y: 20), .init(x: 11, y: 21), .init(x: 12, y: 20),
        ]))
    }

    func testParsesAnnulusAndPoint() throws {
        let regs = try RegionFile.parse("""
        image
        annulus(50, 50, 5, 10)
        point(60, 60)
        """)
        XCTAssertEqual(regs.count, 2)
        XCTAssertEqual(regs[0].shape, .annulus(
            center: .init(x: 50, y: 50),
            innerRadius: .init(value: 5, unit: .pixel),
            outerRadius: .init(value: 10, unit: .pixel)
        ))
        XCTAssertEqual(regs[1].shape, .point(.init(x: 60, y: 60)))
    }

    func testParsesColorAndBracedText() throws {
        let r = try RegionFile.parse("image\ncircle(1,2,3) # color=red text={Star A}")[0]
        XCTAssertEqual(r.attributes["color"], "red")
        XCTAssertEqual(r.attributes["text"], "Star A")
    }

    func testSkipsCommentsAndGlobalDirective() throws {
        let text = """
        # Region file v1.0 — test header line
        global color=green dashlist=8 3 width=1
        image
        circle(1, 2, 3)
        """
        let regs = try RegionFile.parse(text)
        XCTAssertEqual(regs.count, 1)
    }

    func testRoundTripsThroughFormatter() throws {
        let original: [Region] = [
            .init(
                shape: .circle(center: .init(x: 100, y: 200), radius: .init(value: 30, unit: .pixel)),
                frame: .image
            ),
            .init(
                shape: .box(
                    center: .init(x: 50, y: 50),
                    width: .init(value: 5, unit: .arcsecond),
                    height: .init(value: 3, unit: .arcsecond),
                    angle: 30
                ),
                frame: .fk5,
                attributes: ["color": "red"]
            ),
        ]
        let text = RegionFile.format(original)
        let parsed = try RegionFile.parse(text)
        XCTAssertEqual(parsed, original)
    }

    func testParsesEllipseWithAngle() throws {
        let r = try RegionFile.parse("image\nellipse(100, 200, 30, 15, 45)")[0]
        XCTAssertEqual(r.shape, .ellipse(
            center: .init(x: 100, y: 200),
            rx: .init(value: 30, unit: .pixel),
            ry: .init(value: 15, unit: .pixel),
            angle: 45
        ))
    }

    func testRoundTripsEllipseAndPolygon() throws {
        let original: [Region] = [
            .init(
                shape: .ellipse(
                    center: .init(x: 50, y: 50),
                    rx: .init(value: 5, unit: .arcsecond),
                    ry: .init(value: 3, unit: .arcsecond),
                    angle: 30
                ),
                frame: .fk5
            ),
            .init(
                shape: .polygon(points: [
                    .init(x: 10, y: 20),
                    .init(x: 15, y: 25),
                    .init(x: 12, y: 30),
                ]),
                frame: .image
            ),
        ]
        let text = RegionFile.format(original)
        XCTAssertEqual(try RegionFile.parse(text), original)
    }

    func testThrowsOnUnknownShape() {
        // `compass` is not a supported shape; silent skipping hides corrupt input.
        XCTAssertThrowsError(try RegionFile.parse("image\ncompass(100, 200, 30)")) { err in
            guard case RegionError.malformed = err else {
                XCTFail("expected .malformed, got \(err)")
                return
            }
        }
    }

    // MARK: - BUG-5: malformed (no-parens) lines must throw, not silently vanish

    func testThrowsOnMalformedLineWithoutParens() {
        // A shape line with no parentheses was skipped silently, letting a corrupt
        // .reg quietly clear/partial-load the user's regions. It must throw.
        XCTAssertThrowsError(try RegionFile.parse("image\nthis is not a region")) { err in
            guard case RegionError.malformed = err else {
                XCTFail("expected .malformed, got \(err)")
                return
            }
        }
    }

    func testMalformedLineDoesNotSilentlyDropValidRegions() {
        // Mixed valid + no-parens garbage must surface an error rather than
        // returning only the valid subset (silent partial data loss).
        XCTAssertThrowsError(try RegionFile.parse("image\ncircle(1, 2, 3)\ngarbage-no-parens"))
    }

    func testIgnoresUnmodeledCoordinateDirective() throws {
        // `physical` / `wcs` are legitimate DS9 coordinate systems we don't model
        // as a distinct frame; they must be ignored, NOT thrown as malformed —
        // otherwise real DS9 region files fail to load.
        XCTAssertEqual(try RegionFile.parse("physical\ncircle(1, 2, 3)").count, 1)
        XCTAssertEqual(try RegionFile.parse("wcs\ncircle(1, 2, 3)").count, 1)
        XCTAssertEqual(try RegionFile.parse("detector\npoint(5, 5)").count, 1)
    }

    func testSemicolonsSeparateRegionsOutsideTextAndComments() throws {
        let circle = Region.Shape.circle(center: Region.Point(x: 100, y: 100),
                                         radius: Region.Distance(value: 20, unit: .pixel))
        let inline = try RegionFile.parse("image; circle(100,100,20)")
        XCTAssertEqual(inline.map(\.shape), [circle])
        XCTAssertEqual(inline.first?.frame, .image)
        XCTAssertEqual(try RegionFile.parse("circle(100,100,20); point(5,5)").count, 2)
        // A semicolon inside braces, or after the attribute marker, is text.
        let text = try RegionFile.parse("circle(100,100,20) # text={a;b}")
        XCTAssertEqual(text.count, 1)
        XCTAssertEqual(text.first?.attributes["text"], "a;b")
        XCTAssertEqual(try RegionFile.parse("# Region file; DS9\nimage").count, 0)
    }

    func testAcceptsDS9sParenthesisFreeShapes() throws {
        let regions = try RegionFile.parse("circle 100 100 20 # color=red\nbox 5 5 4 4 0")
        XCTAssertEqual(regions.map(\.shape), [
            .circle(center: Region.Point(x: 100, y: 100), radius: Region.Distance(value: 20, unit: .pixel)),
            .box(center: Region.Point(x: 5, y: 5), width: Region.Distance(value: 4, unit: .pixel),
                 height: Region.Distance(value: 4, unit: .pixel), angle: 0),
        ])
        XCTAssertEqual(regions.first?.attributes["color"], "red")
        XCTAssertThrowsError(try RegionFile.parse("circle 100 100"))
    }

    func testParsesImageCircleWithoutAttributes() throws {
        let text = """
        image
        circle(100, 200, 30)
        """
        let regions = try RegionFile.parse(text)
        XCTAssertEqual(regions.count, 1)
        let r = regions[0]
        XCTAssertEqual(r.frame, .image)
        XCTAssertEqual(r.shape, .circle(
            center: Region.Point(x: 100, y: 200),
            radius: Region.Distance(value: 30, unit: .pixel)
        ))
    }
}
