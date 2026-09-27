import Foundation
import XCTest
import FITSCore
@testable import TheiaKit

final class InteractionControllerTests: XCTestCase {
    func testScrollZoomKeepsImagePointUnderCursor() async {
        await MainActor.run {
            let image = FITSImage.fromFloat32(pixels: Array(repeating: 1, count: 100), width: 10, height: 10)
            let view = ImageViewState(image: image, transform: ViewTransform(scale: 2, centre: SIMD2(4.5, 4.5)),
                                      viewSizePoints: CGSize(width: 100, height: 100))
            let controller = InteractionController(view: view, mode: .full)
            let location = SIMD2<Double>(70, 30)
            let before = ViewMapping(transform: view.transform, viewSize: SIMD2(100, 100), backingScale: 1)
                .viewToImage(location)

            XCTAssertTrue(controller.scroll(.init(location: location, deltaY: 100, isPrecise: true)))
            let after = ViewMapping(transform: view.transform, viewSize: SIMD2(100, 100), backingScale: 1)
                .viewToImage(location)
            XCTAssertEqual(view.transform.scale, 2 * pow(1.0015, 100), accuracy: 1e-10)
            XCTAssertEqual(after.x, before.x, accuracy: 1e-10)
            XCTAssertEqual(after.y, before.y, accuracy: 1e-10)
        }
    }

    func testMagnifyUsesFactorAndIgnoresInvalidZoom() async {
        await MainActor.run {
            let image = FITSImage.fromFloat32(pixels: [1], width: 1, height: 1)
            let view = ImageViewState(image: image, transform: ViewTransform(scale: 2, centre: .zero),
                                      viewSizePoints: CGSize(width: 80, height: 80))
            let controller = InteractionController(view: view, mode: .viewOnly)
            XCTAssertTrue(controller.magnify(.init(location: SIMD2(40, 40), factor: 1.25)))
            XCTAssertEqual(view.transform.scale, 2.5)
            XCTAssertFalse(controller.magnify(.init(location: SIMD2(40, 40), factor: -1)))
            XCTAssertFalse(controller.scroll(.init(location: SIMD2(40, 40), deltaY: .infinity, isPrecise: false)))
            XCTAssertEqual(view.transform.scale, 2.5)
        }
    }

    func testPrimaryPanIsModeAwareAndMiddlePanWorksInDrawMode() async {
        await MainActor.run {
            let image = FITSImage.fromFloat32(pixels: [1], width: 1, height: 1)
            let view = ImageViewState(image: image, transform: ViewTransform(scale: 2, centre: SIMD2(4.5, 4.5)),
                                      viewSizePoints: CGSize(width: 100, height: 100))
            let controller = InteractionController(view: view, mode: .full)
            controller.drawMode = .drawCircle
            controller.pointer(.init(phase: .down, button: .primary, location: SIMD2(40, 40)))
            XCTAssertFalse(controller.pointer(.init(phase: .dragged, button: .primary, location: SIMD2(50, 60))))
            XCTAssertEqual(view.transform.centre, SIMD2(4.5, 4.5))

            controller.pointer(.init(phase: .down, button: .middle, location: SIMD2(40, 40)))
            XCTAssertTrue(controller.pointer(.init(phase: .dragged, button: .middle, location: SIMD2(50, 60))))
            XCTAssertEqual(view.transform.centre, SIMD2(-0.5, 14.5))
            controller.pointer(.init(phase: .up, button: .middle, location: SIMD2(50, 60)))
            XCTAssertFalse(controller.pointer(.init(phase: .dragged, button: .middle, location: SIMD2(70, 70))))

            controller.mode = .viewOnly
            controller.pointer(.init(phase: .down, button: .primary, location: SIMD2(40, 40)))
            XCTAssertTrue(controller.pointer(.init(phase: .dragged, button: .primary, location: SIMD2(50, 40))))
            XCTAssertEqual(view.transform.centre, SIMD2(-5.5, 14.5))
        }
    }

    func testSecondaryDragChangesContrastAndBiasFromInitialLevels() async {
        await MainActor.run {
            let image = FITSImage.fromFloat32(pixels: [0, 100], width: 2, height: 1)
            let view = ImageViewState(image: image, viewSizePoints: CGSize(width: 100, height: 100),
                                      vmin: 0, vmax: 100)
            let controller = InteractionController(view: view, mode: .full)
            controller.pointer(.init(phase: .down, button: .secondary, location: SIMD2(50, 50)))
            XCTAssertTrue(controller.pointer(.init(phase: .dragged, button: .secondary,
                                                   location: SIMD2(75, 25))))
            XCTAssertEqual(view.vmin, 50, accuracy: 1e-5)
            XCTAssertEqual(view.vmax, 100, accuracy: 1e-5)
            controller.pointer(.init(phase: .up, button: .secondary, location: SIMD2(75, 25)))
            XCTAssertFalse(controller.pointer(.init(phase: .dragged, button: .secondary,
                                                    location: SIMD2(90, 10))))
        }
    }

    func testKeyboardPlaybackAndPlaneKeysAffectOnlyOwningSession() async throws {
        try await MainActor.run {
            let first = try makeCubeSession()
            let second = try makeCubeSession()
            let firstController = InteractionController(view: first.view, mode: .full, session: first)
            let secondController = InteractionController(view: second.view, mode: .full, session: second)

            XCTAssertTrue(firstController.key(.init(key: .space)))
            XCTAssertTrue(first.playing)
            XCTAssertFalse(second.playing)
            XCTAssertTrue(secondController.key(.init(key: .rightArrow)))
            XCTAssertEqual(first.plane, 0)
            XCTAssertEqual(second.plane, 1)
            XCTAssertTrue(firstController.key(.init(key: .leftArrow)))
            XCTAssertEqual(first.plane, 1)
            XCTAssertEqual(second.plane, 1)
            XCTAssertFalse(firstController.key(.init(key: .space, modifiers: [.primary])))
        }
    }

    func testKeyboardRegionActionsAndEscapeUseSessionHistory() async throws {
        try await MainActor.run {
            let session = try makeCubeSession()
            let controller = InteractionController(view: session.view, mode: .full, session: session)
            let region = Region(shape: .point(.init(x: 20, y: 20)), frame: .image)
            session.perform(.addRegion(region), origin: .user)
            XCTAssertTrue(controller.key(.init(key: .leftArrow, modifiers: [.shift])))
            XCTAssertEqual(session.regions[0].shape, .point(.init(x: 10, y: 20)))
            XCTAssertTrue(controller.key(.init(key: .character("z"), modifiers: [.primary])))
            XCTAssertEqual(session.regions[0], region)
            XCTAssertTrue(controller.key(.init(key: .character("z"), modifiers: [.primary, .shift])))
            XCTAssertEqual(session.regions[0].shape, .point(.init(x: 10, y: 20)))
            XCTAssertTrue(controller.key(.init(key: .character("d"), modifiers: [.primary])))
            XCTAssertEqual(session.regions.count, 2)
            XCTAssertTrue(controller.key(.init(key: .escape)))
            XCTAssertNil(session.selectedRegionIndex)
            XCTAssertFalse(controller.key(.init(key: .delete)))
        }
    }

    func testExtraModifierDoesNotTriggerRegionUndo() async throws {
        try await MainActor.run {
            let session = try makeCubeSession()
            let controller = InteractionController(view: session.view, mode: .full, session: session)
            let region = Region(shape: .point(.init(x: 20, y: 20)), frame: .image)
            session.perform(.addRegion(region), origin: .user)
            session.perform(.nudgeRegion(0, dx: -1, dy: 0), origin: .user)
            XCTAssertFalse(controller.key(.init(key: .character("z"), modifiers: [.primary, .option])))
            XCTAssertEqual(session.regions[0].shape, .point(.init(x: 19, y: 20)))
        }
    }

    @MainActor private func makeCubeSession() throws -> DocumentSession {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8",
            "NAXIS   =                    3", "NAXIS1  =                    2",
            "NAXIS2  =                    2", "NAXIS3  =                    2", "END"
        ]
        var header = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        header += String(repeating: " ", count: 2880 - header.utf8.count)
        var data = Data(header.utf8)
        data.append(contentsOf: Array(0..<8).map(UInt8.init))
        data.append(Data(repeating: 0, count: 2880 - 8))
        return DocumentSession(url: URL(fileURLWithPath: "/tmp/interaction-cube.fits"),
                               file: try FITSFile(data: data))
    }
}
