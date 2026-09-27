import AppKit
import XCTest
import FITSCore
import TheiaKit
@testable import FITSViewerApp

@MainActor final class PanelBindingTests: XCTestCase {
    func testPixelTableRebindsImageAndCursorWhenAnotherDocumentOpensIt() throws {
        let first = FITSImage.fromFloat32(pixels: [1], width: 1, height: 1)
        let second = FITSImage.fromFloat32(pixels: [9], width: 1, height: 1)
        let firstBridge = PixelTableCursorBridge()
        let secondBridge = PixelTableCursorBridge()
        PixelTableWindowController.show(provider: { first }, cursorPublisher: firstBridge, attachedTo: nil)
        defer { PixelTableWindowController.shared?.window?.close() }
        let original = try XCTUnwrap(PixelTableWindowController.shared)

        PixelTableWindowController.focus(provider: { second }, cursorPublisher: secondBridge)

        XCTAssertTrue(PixelTableWindowController.shared === original)
        XCTAssertTrue(original.boundCursorBridge === secondBridge)
        XCTAssertEqual(original.boundImageProvider?()?.physicalValue(x: 0, y: 0), 9)
    }

    func testContourPanelRebindsModelAndChangesToFocusedDocument() throws {
        let first = ContourLevelsModel(initial: ContourSpec(enabled: true, count: 2),
                                       dataMin: 1, dataMax: 2)
        let second = ContourLevelsModel(initial: ContourSpec(enabled: false, count: 5),
                                        dataMin: 9, dataMax: 20)
        var firstChangeCount = 0
        var secondChangeCount = 0
        ContourLevelsWindowController.show(model: first, onChange: { _ in firstChangeCount += 1 }, attachedTo: nil)
        defer { ContourLevelsWindowController.shared?.window?.close() }
        let original = try XCTUnwrap(ContourLevelsWindowController.shared)

        ContourLevelsWindowController.focus(modelProvider: { second },
                                            onChange: { _ in secondChangeCount += 1 })
        original.boundOnChange?(ContourSpec(enabled: true, count: 4))

        XCTAssertTrue(ContourLevelsWindowController.shared === original)
        XCTAssertEqual(original.boundModel?.spec.count, 5)
        XCTAssertEqual(original.boundModel?.dataMin, 9)
        XCTAssertEqual(firstChangeCount, 0)
        XCTAssertEqual(secondChangeCount, 1)
    }

    func testContourRangeIsNotReadWhenPanelIsClosed() {
        ContourLevelsWindowController.shared?.window?.close()
        var rangeReads = 0
        ContourLevelsWindowController.focus(modelProvider: {
            rangeReads += 1
            return ContourLevelsModel(initial: ContourSpec(), dataMin: 1, dataMax: 2)
        }, onChange: { _ in })
        XCTAssertEqual(rangeReads, 0)
    }

    func testScaleParametersReusesPanelPerViewportAndReleasesItOnClose() throws {
        let first = ImageViewState()
        let second = ImageViewState()
        let firstPanel = ScaleParametersWindowController.show(
            viewport: first, physicalValuesProvider: { [] }, onApplyPreset: { _ in }, attachedTo: nil)
        let reopened = ScaleParametersWindowController.show(
            viewport: first, physicalValuesProvider: { [] }, onApplyPreset: { _ in }, attachedTo: nil)
        let secondPanel = ScaleParametersWindowController.show(
            viewport: second, physicalValuesProvider: { [] }, onApplyPreset: { _ in }, attachedTo: nil)

        XCTAssertTrue(firstPanel === reopened)
        XCTAssertFalse(firstPanel === secondPanel)
        firstPanel.window?.close()
        let afterClose = ScaleParametersWindowController.show(
            viewport: first, physicalValuesProvider: { [] }, onApplyPreset: { _ in }, attachedTo: nil)
        defer { afterClose.window?.close() }
        XCTAssertFalse(firstPanel === afterClose)

        ScaleParametersWindowController.close(for: second)
        let afterDocumentClose = ScaleParametersWindowController.show(
            viewport: second, physicalValuesProvider: { [] }, onApplyPreset: { _ in }, attachedTo: nil)
        defer { afterDocumentClose.window?.close() }
        XCTAssertFalse(secondPanel === afterDocumentClose)
    }

    func testLineProfileCloseInvokesMarkerCleanup() {
        let image = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let model = LineProfileModel(image: image, from: SIMD2(0, 0), to: SIMD2(1, 1))
        var closed = 0
        LineProfileWindowController.show(model: model, imageName: "first", attachedTo: nil,
                                         onClose: { closed += 1 })
        LineProfileWindowController.shared?.window?.close()
        XCTAssertEqual(closed, 1)
    }

    func testProfileWindowClearsOnlyTheMarkerItOwns() throws {
        let session = try makeSession()
        let image = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        let first = ProfileGeometry.line(from: SIMD2(0, 0), to: SIMD2(1, 1))
        let second = ProfileGeometry.line(from: SIMD2(1, 0), to: SIMD2(0, 1))
        let model = LineProfileModel(image: image, from: SIMD2(0, 0), to: SIMD2(1, 1))

        session.profileMarker = first
        LineProfileWindowController.show(model: model, imageName: "first", attachedTo: nil,
                                         onClose: ProfileWindowMarker.onClose(first, in: session))
        session.profileMarker = second
        LineProfileWindowController.show(model: model, imageName: "second", attachedTo: nil,
                                         onClose: ProfileWindowMarker.onClose(second, in: session))
        XCTAssertEqual(session.profileMarker, second)

        LineProfileWindowController.shared?.window?.close()
        XCTAssertNil(session.profileMarker)
    }

    func testProfileCloseHandlerDoesNotRetainDocumentSession() throws {
        var session: DocumentSession? = try makeSession()
        weak let weakSession = session
        let callback = ProfileWindowMarker.onClose(.point(SIMD2(0, 0)), in: try XCTUnwrap(session))
        session = nil
        XCTAssertNil(weakSession)
        callback()
    }

    func testRadialAndGrowthCloseHandlersClearResizedMarkersWithoutRetainingSession() throws {
        var session: DocumentSession? = try makeSession()
        let center = SIMD2<Double>(1, 1)
        let radialClose = ProfileWindowMarker.onRadialClose(center: center,
                                                             in: try XCTUnwrap(session))
        session?.profileMarker = .radial(center: center, maxRadius: 8)
        radialClose()
        XCTAssertNil(session?.profileMarker)

        let growthClose = ProfileWindowMarker.onGrowthClose(center: center,
                                                             in: try XCTUnwrap(session))
        session?.profileMarker = .growth(center: center, maxRadius: 12)
        growthClose()
        XCTAssertNil(session?.profileMarker)

        weak let weakSession = session
        session = nil
        XCTAssertNil(weakSession)
        radialClose()
        growthClose()
    }

    private func makeSession() throws -> DocumentSession {
        let cards = ["SIMPLE  =                    T", "BITPIX  =                    8",
                     "NAXIS   =                    2", "NAXIS1  =                    2",
                     "NAXIS2  =                    2", "END"]
        let header = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        let data = Data(header.padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            + Data([1, 2, 3, 4]) + Data(repeating: 0, count: 2876)
        return DocumentSession(url: URL(fileURLWithPath: "/tmp/panel-marker-test.fits"),
                               file: try FITSFile(data: data))
    }

    func testCubeSpectrumCloseInvokesMarkerCleanup() {
        let model = CubeSpectrumModel(values: [1, 2], currentPlane: 0, label: "pixel",
                                      xValues: nil, xLabel: "plane")
        var closed = 0
        CubeSpectrumWindowController.show(model: model, attachedTo: nil, onClose: { closed += 1 })
        CubeSpectrumWindowController.shared?.window?.close()
        XCTAssertEqual(closed, 1)
    }

    func testPVDiagramCloseInvokesMarkerCleanup() {
        let image = FITSImage.fromFloat32(pixels: [1, 2, 3, 4], width: 2, height: 2)
        var closed = 0
        PVDiagramWindowController.show(image: image, imageName: "cube", attachedTo: nil,
                                       onClose: { closed += 1 })
        PVDiagramWindowController.shared?.window?.close()
        XCTAssertEqual(closed, 1)
    }
}
