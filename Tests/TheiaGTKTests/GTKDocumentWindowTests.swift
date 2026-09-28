import CGtk4
import FITSCore
import Foundation
import Glibc
import TheiaKit
import XCTest
@testable import TheiaGTK

@MainActor private func documentWindowID(matching title: String = "uint8_simple.fits — Theia") throws -> String {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        _ = g_main_context_iteration(nil, 0)
        let search = Process()
        search.executableURL = URL(fileURLWithPath: "/usr/bin/xwininfo")
        search.arguments = ["-root", "-tree"]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C.utf8"
        search.environment = environment
        let output = Pipe()
        search.standardOutput = output
        try search.run()
        search.waitUntilExit()
        if search.terminationStatus == 0,
           let identifier = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n")
            .first(where: { $0.contains(title) })?
            .split(whereSeparator: \.isWhitespace).first.map(String.init) {
            return identifier
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
    let notFound: String? = nil
    return try XCTUnwrap(notFound, "GTK document window was not mapped by Xvfb")
}

@MainActor private func waitForCanvas(
    _ window: GTKDocumentWindow,
    using bridge: GTKMainLoopBridge? = nil,
    timeout: TimeInterval = 5,
    matching predicate: (OpaquePointer?) -> Bool
) async throws -> OpaquePointer {
    let temporaryBridge = bridge == nil ? GTKMainLoopBridge() : nil
    XCTAssertTrue((bridge ?? temporaryBridge)?.install() == true)
    defer { temporaryBridge?.remove() }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        _ = g_main_context_iteration(nil, 0)
        let paintable = gtk_picture_get_paintable(window.picture)
        if predicate(paintable) { return try XCTUnwrap(paintable) }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    let picture = UnsafeMutablePointer<GtkWidget>(window.picture)
    let size = window.session.view.viewSizePoints
    return try XCTUnwrap(nil as OpaquePointer?, "GTK canvas did not finish rendering "
        + "(picture \(gtk_widget_get_width(picture))×\(gtk_widget_get_height(picture)), "
        + "view \(size.width)×\(size.height), mapped \(gtk_widget_get_mapped(picture)))")
}

@MainActor private func canvasCenter(in window: GTKDocumentWindow) -> (Int, Int) {
    let picture = UnsafeMutablePointer<GtkWidget>(window.picture)
    var originX = 0.0
    var originY = 0.0
    XCTAssertEqual(gtk_widget_translate_coordinates(
        picture, UnsafeMutablePointer<GtkWidget>(OpaquePointer(window.widget)),
        0, 0, &originX, &originY
    ), 1)
    let x = Int((originX + Double(gtk_widget_get_width(picture)) / 2).rounded())
    let y = Int((originY + Double(gtk_widget_get_height(picture)) / 2).rounded())
    return (x, y)
}

@MainActor private func gtkCubeSession() throws -> DocumentSession {
    let cards = [
        "SIMPLE  =                    T", "BITPIX  =                    8",
        "NAXIS   =                    3", "NAXIS1  =                    1",
        "NAXIS2  =                    1", "NAXIS3  =                    3", "END",
    ]
    var header = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
    header += String(repeating: " ", count: 2880 - header.utf8.count)
    var data = Data(header.utf8)
    data.append(contentsOf: [2, 3, 5])
    data.append(Data(repeating: 0, count: 2880 - 3))
    return DocumentSession(url: URL(fileURLWithPath: "/tmp/theia-gtk-cube.fits"),
                           file: try FITSFile(data: data))
}

@MainActor private func gtkTableSession() throws -> DocumentSession {
    func block(_ cards: [String]) -> Data {
        let text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        return Data((text + String(repeating: " ", count: 2880 - text.utf8.count)).utf8)
    }
    let primary = block([
        "SIMPLE  =                    T", "BITPIX  =                    8",
        "NAXIS   =                    0", "EXTEND  =                    T", "END",
    ])
    let extensionHeader = block([
        "XTENSION= 'BINTABLE'", "BITPIX  =                    8",
        "NAXIS   =                    2", "NAXIS1  =                    1",
        "NAXIS2  =                  105", "PCOUNT  =                    0",
        "GCOUNT  =                    1", "TFIELDS =                    1",
        "TTYPE1  = 'id'", "TFORM1  = '1B'", "END",
    ])
    var rows = Data((0..<105).map(UInt8.init))
    rows.append(Data(repeating: 0, count: 2880 - rows.count))
    return DocumentSession(url: URL(fileURLWithPath: "/tmp/theia-gtk-table.fits"),
                           file: try FITSFile(data: primary + extensionHeader + rows))
}

final class GTKDocumentWindowTests: XCTestCase {
    @MainActor func testHeaderInspectorFiltersEditsAndRequestsModifiedFITS() async throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fixture,
                                      file: try FITSFile(data: Data(contentsOf: fixture)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        window.present()
        for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }
        let page = try XCTUnwrap(gtk_notebook_get_nth_page(window.inspector.notebook, 0))
        let toolbar = try XCTUnwrap(gtk_widget_get_first_child(page))
        let search = try XCTUnwrap(gtk_widget_get_first_child(toolbar))
        let edit = try XCTUnwrap(gtk_widget_get_next_sibling(search))
        let save = try XCTUnwrap(gtk_widget_get_next_sibling(edit))
        XCTAssertEqual(gtk_widget_get_sensitive(save), 0)
        gtk_editable_set_text(OpaquePointer(search), "OBJECT")
        XCTAssertTrue(window.inspector.headerText.contains("OBJECT"))
        XCTAssertFalse(window.inspector.headerText.contains("BITPIX"))
        gtk_toggle_button_set_active(
            UnsafeMutablePointer<GtkToggleButton>(OpaquePointer(edit)), 1
        )
        XCTAssertTrue(session.headerEditor.editing)
        let row = try XCTUnwrap(gtk_list_box_get_row_at_index(window.inspector.headerEditList, 0))
        let content = try XCTUnwrap(gtk_list_box_row_get_child(row))
        let keyword = try XCTUnwrap(gtk_widget_get_first_child(content))
        let value = try XCTUnwrap(gtk_widget_get_next_sibling(keyword))
        gtk_editable_set_text(OpaquePointer(value), "'Linux edit'")
        XCTAssertEqual(session.headerEditor.editCount(for: 0), 1)
        XCTAssertEqual(gtk_widget_get_sensitive(save), 1)
        var requestedHDU: Int?
        var requestedCards: [String] = []
        window.inspector.onSaveHeader = { hdu, cards in
            requestedHDU = hdu
            requestedCards = cards
        }
        let id = try documentWindowID()
        var saveX = 0.0, saveY = 0.0
        XCTAssertEqual(gtk_widget_translate_coordinates(
            save, UnsafeMutablePointer<GtkWidget>(OpaquePointer(window.widget)),
            Double(gtk_widget_get_width(save)) / 2,
            Double(gtk_widget_get_height(save)) / 2,
            &saveX, &saveY
        ), 1)
        let click = Process()
        click.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
        click.arguments = ["mousemove", "--window", id, String(Int(saveX)),
                           String(Int(saveY)), "click", "1"]
        try click.run()
        let deadline = Date().addingTimeInterval(2)
        while (click.isRunning || requestedHDU == nil) && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        click.waitUntilExit()
        XCTAssertEqual(click.terminationStatus, 0)
        XCTAssertEqual(requestedHDU, 0)
        XCTAssertTrue(requestedCards.contains { $0.contains("OBJECT") && $0.contains("Linux edit") })
        window.inspector.didSaveHeader(hdu: 0)
        XCTAssertEqual(session.headerEditor.editCount(for: 0), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(save), 0)
    }

    @MainActor func testCubeLineDragOpensRenderedPVDiagram() async throws {
        gtk_init()
        let session = try gtkCubeSession()
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let bridge = GTKMainLoopBridge()
        XCTAssertTrue(bridge.install())
        defer { bridge.remove() }
        let window = GTKDocumentWindow(application: application, session: session)
        window.present()
        let id = try documentWindowID(matching: "theia-gtk-cube.fits — Theia")
        for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }
        _ = session.perform(.setDrawMode(.lineProfile), origin: .user)
        let (x, y) = canvasCenter(in: window)
        let drag = Process()
        drag.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
        drag.arguments = [
            "mousemove", "--window", id, String(x), String(y), "sleep", "0.1",
            "mousedown", "1", "sleep", "0.1",
            "mousemove", "--window", id, String(x + 30), String(y),
            "sleep", "0.1", "mouseup", "1",
        ]
        try drag.run()
        let deadline = Date().addingTimeInterval(3)
        while (drag.isRunning || window.pvWindow == nil ||
               window.pvWindow.flatMap({ gtk_picture_get_paintable($0.picture) }) == nil)
                && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        drag.waitUntilExit()
        XCTAssertEqual(drag.terminationStatus, 0)
        let pv = try XCTUnwrap(window.pvWindow)
        XCTAssertGreaterThanOrEqual(pv.image.width, 64)
        XCTAssertEqual(pv.image.height, 3)
        XCTAssertNotNil(gtk_picture_get_paintable(pv.picture))
        XCTAssertNil(gtk_window_get_transient_for(pv.widget))
        gtk_window_destroy(window.widget)
        XCTAssertNil(window.pvWindow)
        XCTAssertNil(session.profileMarker)
    }

    @MainActor func testCubeSpectrumClickOpensPlotWithPlaneValues() async throws {
        gtk_init()
        let session = try gtkCubeSession()
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let bridge = GTKMainLoopBridge()
        XCTAssertTrue(bridge.install())
        defer { bridge.remove() }
        let window = GTKDocumentWindow(application: application, session: session)
        window.present()
        let id = try documentWindowID(matching: "theia-gtk-cube.fits — Theia")
        for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }
        _ = session.perform(.setDrawMode(.cubeSpectrum), origin: .user)
        let (x, y) = canvasCenter(in: window)
        let click = Process()
        click.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
        click.arguments = ["mousemove", "--window", id, String(x), String(y),
                           "sleep", "0.1", "click", "1"]
        try click.run()
        let deadline = Date().addingTimeInterval(3)
        while (click.isRunning || window.cubeSpectrumWindow == nil) && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        click.waitUntilExit()
        XCTAssertEqual(click.terminationStatus, 0)
        let plot = try XCTUnwrap(window.cubeSpectrumWindow)
        XCTAssertEqual(plot.sampleCount, 3)
        XCTAssertEqual(window.cubeSpectrumModel?.ys, [2, 3, 5])
        XCTAssertEqual(window.cubeSpectrumModel?.xs, [0, 1, 2])
        XCTAssertNil(gtk_window_get_transient_for(plot.widget))
        guard case .point = session.profileMarker else {
            return XCTFail("Expected cube spectrum point marker")
        }
        gtk_window_destroy(window.widget)
        XCTAssertNil(window.cubeSpectrumWindow)
        XCTAssertNil(window.cubeSpectrumModel)
        XCTAssertNil(session.profileMarker)
    }

    @MainActor func testCircularProfileDragsAndControlsUpdateSharedModels() async throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fixture,
                                      file: try FITSFile(data: Data(contentsOf: fixture)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let bridge = GTKMainLoopBridge()
        XCTAssertTrue(bridge.install())
        defer { bridge.remove() }
        let window = GTKDocumentWindow(application: application, session: session)
        window.present()
        let id = try documentWindowID()
        for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }

        for mode in [DrawMode.radialProfile, .growthCurve] {
            _ = session.perform(.setDrawMode(mode), origin: .user)
            XCTAssertEqual(session.mode, mode)
            XCTAssertEqual(window.interaction.drawMode, mode)
            let (x, y) = canvasCenter(in: window)
            let drag = Process()
            drag.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
            drag.arguments = [
                "mousemove", "--window", id, String(x), String(y), "sleep", "0.1",
                "mousedown", "1", "sleep", "0.1",
                "mousemove", "--window", id, String(x + 30), String(y),
                "sleep", "0.1", "mouseup", "1",
            ]
            try drag.run()
            let deadline = Date().addingTimeInterval(3)
            func activePlot() -> GTKPlotWindow? {
                mode == .radialProfile ? window.radialProfileWindow : window.growthCurveWindow
            }
            while (drag.isRunning || (activePlot()?.sampleCount ?? 0) == 0) && Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            drag.waitUntilExit()
            XCTAssertEqual(drag.terminationStatus, 0)
            let plot = try XCTUnwrap(activePlot(), "\(mode): marker=\(String(describing: session.profileMarker))")
            XCTAssertGreaterThan(plot.sampleCount, 0)
            XCTAssertNil(gtk_window_get_transient_for(plot.widget))

            let label = try XCTUnwrap(gtk_widget_get_first_child(
                UnsafeMutablePointer<GtkWidget>(OpaquePointer(plot.controls))
            ))
            let radiusSpin = try XCTUnwrap(gtk_widget_get_next_sibling(label))
            gtk_spin_button_set_value(OpaquePointer(radiusSpin), 1.5)
            _ = g_main_context_iteration(nil, 0)
            switch mode {
            case .radialProfile:
                XCTAssertEqual(window.radialProfileModel?.radius, 1.5)
                guard case .radial(_, let markerRadius) = session.profileMarker else {
                    return XCTFail("Expected radial marker")
                }
                XCTAssertEqual(markerRadius, 1.5)
            case .growthCurve:
                XCTAssertEqual(window.growthCurveModel?.radius, 1.5)
                guard case .growth(_, let markerRadius) = session.profileMarker else {
                    return XCTFail("Expected growth marker")
                }
                XCTAssertEqual(markerRadius, 1.5)
            default: break
            }
            let nextLabel = try XCTUnwrap(gtk_widget_get_next_sibling(radiusSpin))
            let nextSpin = try XCTUnwrap(gtk_widget_get_next_sibling(nextLabel))
            gtk_spin_button_set_value(OpaquePointer(nextSpin), 0.5)
            _ = g_main_context_iteration(nil, 0)
            if mode == .radialProfile {
                XCTAssertEqual(window.radialProfileModel?.binWidth, 0.5)
            } else {
                XCTAssertEqual(window.growthCurveModel?.step, 0.5)
            }
            let updateDeadline = Date().addingTimeInterval(2)
            while plot.sampleCount == 0 && Date() < updateDeadline {
                _ = g_main_context_iteration(nil, 0)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertGreaterThan(plot.sampleCount, 0)
            gtk_window_destroy(plot.widget)
            XCTAssertNil(session.profileMarker)
        }
        gtk_window_destroy(window.widget)
        XCTAssertNil(window.radialProfileWindow)
        XCTAssertNil(window.growthCurveWindow)
        XCTAssertNil(window.radialProfileModel)
        XCTAssertNil(window.growthCurveModel)
        XCTAssertNil(session.profileMarker)
    }

    @MainActor func testLineProfileDragOpensIndependentPlotWindow() async throws {
            gtk_init()
            let fixture = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            let session = DocumentSession(url: fixture,
                                          file: try FITSFile(data: Data(contentsOf: fixture)))
            let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
            defer { g_object_unref(UnsafeMutableRawPointer(application)) }
            XCTAssertEqual(g_application_register(
                UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
            ), 1)
            let bridge = GTKMainLoopBridge()
            XCTAssertTrue(bridge.install())
            defer { bridge.remove() }
            let window = GTKDocumentWindow(application: application, session: session)
            window.present()
            let id = try documentWindowID()
            for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }
            _ = session.perform(.setDrawMode(.lineProfile), origin: .user)
            let (x, y) = canvasCenter(in: window)
            let drag = Process()
            drag.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
            drag.arguments = [
                "mousemove", "--window", id, String(x), String(y), "sleep", "0.1",
                "mousedown", "1", "sleep", "0.1",
                "mousemove", "--window", id, String(x + 30), String(y),
                "sleep", "0.1", "mouseup", "1",
            ]
            try drag.run()
            let deadline = Date().addingTimeInterval(3)
            while (drag.isRunning || window.lineProfileWindow == nil ||
                   window.lineProfileWindow?.sampleCount == 0) && Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            drag.waitUntilExit()
            XCTAssertEqual(drag.terminationStatus, 0)
            let plot = try XCTUnwrap(window.lineProfileWindow)
            XCTAssertGreaterThanOrEqual(plot.sampleCount, 64)
            XCTAssertNil(gtk_window_get_transient_for(plot.widget))
            guard case .line = session.profileMarker else {
                return XCTFail("Expected the shared line marker")
            }
            gtk_window_destroy(window.widget)
            XCTAssertNil(window.lineProfileWindow)
            XCTAssertNil(session.profileMarker)
    }

    func testRegionRightClickOpensSharedContextActions() async throws {
        try await MainActor.run {
            gtk_init()
            let fixture = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            let session = DocumentSession(url: fixture,
                                          file: try FITSFile(data: Data(contentsOf: fixture)))
            let image = try XCTUnwrap(session.displayed)
            let target = SIMD2((Double(image.width) - 1) / 2,
                               (Double(image.height) - 1) / 2)
            session.regions = [Region(
                shape: .circle(center: .init(x: target.x + 1, y: target.y + 1),
                               radius: .init(value: 0.4, unit: .pixel)), frame: .image
            )]
            let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
            defer { g_object_unref(UnsafeMutableRawPointer(application)) }
            XCTAssertEqual(g_application_register(
                UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
            ), 1)
            let window = GTKDocumentWindow(application: application, session: session)
            defer { gtk_window_destroy(window.widget) }
            window.present()
            let id = try documentWindowID()
            for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }
            let picture = UnsafeMutablePointer<GtkWidget>(window.picture)
            let mapping = ViewMapping(
                transform: session.view.transform,
                viewSize: SIMD2(Double(gtk_widget_get_width(picture)),
                                Double(gtk_widget_get_height(picture))), backingScale: 1
            )
            let point = mapping.imageToView(target)
            XCTAssertEqual(gtk_widget_contains(picture, point.x, point.y), 1)
            var x = 0.0, y = 0.0
            XCTAssertEqual(gtk_widget_translate_coordinates(
                picture, UnsafeMutablePointer<GtkWidget>(OpaquePointer(window.widget)),
                point.x, point.y, &x, &y
            ), 1)
            let click = Process()
            click.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
            click.arguments = ["mousemove", "--window", id, String(Int(x)), String(Int(y)),
                               "sleep", "0.1", "click", "3"]
            try click.run()
            let deadline = Date().addingTimeInterval(2)
            while (click.isRunning || window.regionPopover == nil) && Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            click.waitUntilExit()
            XCTAssertEqual(click.terminationStatus, 0)
            XCTAssertEqual(session.selectedRegionIndex, 0)
            let popover = try XCTUnwrap(window.regionPopover)
            let content = try XCTUnwrap(gtk_popover_get_child(popover))
            let duplicate = try XCTUnwrap(gtk_widget_get_first_child(content))
            XCTAssertEqual(String(cString: gtk_button_get_label(
                UnsafeMutablePointer<GtkButton>(OpaquePointer(duplicate))
            )), "Duplicate")
            XCTAssertEqual(gtk_widget_activate(duplicate), 1)
            let actionDeadline = Date().addingTimeInterval(1)
            while session.regions.count == 1 && Date() < actionDeadline {
                _ = g_main_context_iteration(nil, 0)
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertEqual(session.regions.count, 2)
            XCTAssertNil(window.regionPopover)
        }
    }

    @MainActor func testClosingDocumentCancelsPrintPreparation() async throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fixture,
                                      file: try FITSFile(data: Data(contentsOf: fixture)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        window.commandMenus.activate("file.print")
        XCTAssertNotNil(window.activePrintJob)
        gtk_window_destroy(window.widget)
        XCTAssertNil(window.activePrintJob)
        let bridge = GTKMainLoopBridge()
        XCTAssertTrue(bridge.install())
        defer { bridge.remove() }
        for _ in 0..<20 {
            _ = g_main_context_iteration(nil, 0)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor func testPixelTableMenuTracksCursorAndClosesWithDocument() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL,
                                      file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let document = GTKDocumentWindow(application: application, session: session)
        document.commandMenus.activate("image.pixelTable")
        let table = try XCTUnwrap(document.pixelTableWindow)
        XCTAssertEqual(String(cString: gtk_window_get_title(table.widget)), "Pixel Table")
        XCTAssertTrue(String(cString: gtk_label_get_text(table.footer)).contains("Move the cursor"))

        let value = try XCTUnwrap(session.displayed).physicalValue(x: 0, y: 0)
        session.cursor = CursorInfo(imageX: 0, imageY: 0, value: value)
        XCTAssertTrue(String(cString: gtk_label_get_text(table.footer)).contains("(1, 1)"))
        let firstCell = try XCTUnwrap(gtk_widget_get_first_child(
            UnsafeMutablePointer<GtkWidget>(OpaquePointer(table.grid))
        ))
        session.cursor = CursorInfo(imageX: 1, imageY: 0,
                                    value: try XCTUnwrap(session.displayed).physicalValue(x: 1, y: 0))
        XCTAssertEqual(gtk_widget_get_first_child(
            UnsafeMutablePointer<GtkWidget>(OpaquePointer(table.grid))
        ), firstCell)
        document.commandMenus.activate("image.pixelTable")
        XCTAssertTrue(table === document.pixelTableWindow)
        gtk_window_destroy(document.widget)
        XCTAssertNil(document.pixelTableWindow)
    }

    @MainActor func testContourPanelAppliesSpecificationToSourceDocument() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL,
                                      file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let document = GTKDocumentWindow(application: application, session: session)
        document.commandMenus.activate("image.contours")
        let panel = try XCTUnwrap(document.contourLevelsWindow)
        gtk_check_button_set_active(panel.enabled, 1)
        gtk_spin_button_set_value(panel.count, 4)
        gtk_editable_set_text(panel.minimum, "10")
        gtk_editable_set_text(panel.maximum, "40")
        panel.apply()
        XCTAssertTrue(session.contourSpec.enabled)
        XCTAssertEqual(session.contourSpec.count, 4)
        XCTAssertEqual(session.contourSpec.levels(), [10, 20, 30, 40])
        gtk_window_destroy(document.widget)
        XCTAssertNil(document.contourLevelsWindow)
    }

    @MainActor func testScalePanelAppliesFiniteLimits() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL,
                                      file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let document = GTKDocumentWindow(application: application, session: session)
        document.commandMenus.activate("scale.parameters")
        let panel = try XCTUnwrap(document.scaleParametersWindow)
        gtk_editable_set_text(panel.minimum, "10")
        gtk_editable_set_text(panel.maximum, "40")
        panel.applyLimits()
        XCTAssertEqual(session.view.vmin, 10)
        XCTAssertEqual(session.view.vmax, 40)
        gtk_editable_set_text(panel.minimum, "50")
        panel.applyLimits()
        XCTAssertEqual(session.view.vmin, 10)
        gtk_window_destroy(document.widget)
        XCTAssertNil(document.scaleParametersWindow)
    }

    @MainActor func testFITSWindowHasTitleAndRenderedCanvas() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"))
        let file = try FITSFile(data: Data(contentsOf: fileURL))
        let session = DocumentSession(url: fileURL, file: file)
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)

        let documentWindow = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(documentWindow.widget) }

        XCTAssertEqual(String(cString: gtk_window_get_title(documentWindow.widget)), "uint8_simple.fits — Theia")
        XCTAssertNil(gtk_picture_get_paintable(documentWindow.picture))
        let paintable = try await waitForCanvas(documentWindow) { $0 != nil }
        XCTAssertEqual(gdk_texture_get_width(paintable), 640)
        XCTAssertEqual(gdk_texture_get_height(paintable), 480)
    }

    @MainActor func testColormapChangeReplacesCanvasTexture() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }

        @MainActor func downloadedPixels() async throws -> [UInt8] {
            let texture = try await waitForCanvas(window) { $0 != nil }
            var bytes = [UInt8](repeating: 0, count: 640 * 480 * 4)
            bytes.withUnsafeMutableBufferPointer { buffer in
                gdk_texture_download(texture, buffer.baseAddress, 640 * 4)
            }
            return bytes
        }

        let gray = try await downloadedPixels()
        let previous = try XCTUnwrap(gtk_picture_get_paintable(window.picture))
        g_object_ref(UnsafeMutableRawPointer(previous))
        defer { g_object_unref(UnsafeMutableRawPointer(previous)) }
        session.view.colorMap = .viridis
        _ = try await waitForCanvas(window) { $0 != nil && $0 != previous }
        let viridis = try await downloadedPixels()
        XCTAssertTrue(viridis != gray)
    }

    @MainActor func testRegionChangesUpdateOverlayWithoutReplacingImageTexture() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        let texture = try await waitForCanvas(window) { $0 != nil }

        session.regions = [Region(shape: .point(.init(x: 1, y: 1)), frame: .image)]

        XCTAssertFalse(window.overlayPrimitives.isEmpty)
        XCTAssertEqual(gtk_picture_get_paintable(window.picture), texture)
    }

    @MainActor func testNativeMenusUseSharedCommandsAndRefreshSelection() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }

        XCTAssertEqual(window.commandMenus.sectionCount, 11)
        XCTAssertNotNil(gtk_widget_get_parent(window.commandMenus.widget))
        XCTAssertEqual(window.commandMenus.title(for: "map.viridis"), "Viridis")
        XCTAssertFalse(window.commandMenus.isEnabled("region.clear"))

        window.commandMenus.activate("map.viridis")

        XCTAssertEqual(session.view.colorMap.rawValue, "viridis")
        XCTAssertEqual(window.commandMenus.title(for: "map.viridis"), "✓ Viridis")
        window.commandMenus.activate("image.colorBar")
        XCTAssertTrue(session.showColorBar)
        session.regions = [Region(shape: .point(.init(x: 1, y: 1)), frame: .image)]
        XCTAssertTrue(window.commandMenus.isEnabled("region.clear"))
    }

    @MainActor func testHeaderCardsKeepOneLineLikeTheMacTable() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }

        let header = UnsafeMutablePointer<GtkTextView>(window.inspector.headerView)
        XCTAssertEqual(gtk_text_view_get_wrap_mode(header), GTK_WRAP_NONE)
        XCTAssertEqual(gtk_text_view_get_monospace(header), 1)
    }

    @MainActor func testWideWindowGivesSpareWidthToTheImage() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        window.present()
        let image = UnsafeMutablePointer<GtkWidget>(window.imageOverlay)
        let deadline = Date().addingTimeInterval(2)
        while gtk_widget_get_width(image) == 0 && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
        }

        // Only the image expands: the side panels keep their natural width.
        var sidebarNatural: Int32 = 0
        var inspectorNatural: Int32 = 0
        gtk_widget_measure(UnsafeMutablePointer<GtkWidget>(window.hduList),
                           GTK_ORIENTATION_HORIZONTAL, -1, nil, &sidebarNatural, nil, nil)
        gtk_widget_measure(window.inspector.widget, GTK_ORIENTATION_HORIZONTAL, -1,
                           nil, &inspectorNatural, nil, nil)
        XCTAssertLessThanOrEqual(gtk_widget_get_width(window.inspector.widget), inspectorNatural)
        let windowWidth = gtk_widget_get_width(UnsafeMutablePointer<GtkWidget>(OpaquePointer(window.widget)))
        XCTAssertGreaterThanOrEqual(gtk_widget_get_width(image),
                                    windowWidth - sidebarNatural - inspectorNatural - 24)
    }

    @MainActor func testInspectorTracksSharedTabVisibilityAndRegions() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }

        XCTAssertEqual(gtk_widget_get_visible(window.inspector.widget), 1)
        XCTAssertTrue(window.inspector.headerText.contains("SIMPLE"))
        _ = session.perform(.setInspectorVisible(false), origin: .user)
        XCTAssertEqual(gtk_widget_get_visible(window.inspector.widget), 0)

        _ = session.perform(.showInspectorTab(.regions), origin: .user)
        XCTAssertEqual(gtk_widget_get_visible(window.inspector.widget), 1)
        XCTAssertEqual(gtk_notebook_get_current_page(window.inspector.notebook), 1)
        session.regions = [Region(shape: .point(.init(x: 1, y: 1)), frame: .image)]
        XCTAssertNotNil(gtk_list_box_get_row_at_index(window.inspector.regionList, 0))
        let row = try XCTUnwrap(gtk_list_box_get_row_at_index(window.inspector.regionList, 0))
        gtk_list_box_select_row(window.inspector.regionList, row)
        XCTAssertEqual(session.selectedRegionIndex, 0)

        _ = session.perform(.showInspectorTab(.photometry), origin: .user)
        await session.photometry.idle()
        for _ in 0..<20 where !window.inspector.photometryText.contains("sum") {
            await Task.yield()
        }
        XCTAssertTrue(window.inspector.photometryText.contains("sum"))

        _ = session.perform(.showInspectorTab(.stats), origin: .user)
        await session.statistics.idle()
        for _ in 0..<20 where !window.inspector.statsText.contains("Pixels") {
            await Task.yield()
        }
        XCTAssertTrue(window.inspector.statsText.contains("Pixels"))
    }

    @MainActor func testRegionSaveMenuOpensNativePathDialog() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        session.regions = [Region(shape: .point(.init(x: 1, y: 1)), frame: .image)]
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }

        window.commandMenus.activate("region.save")

        let dialog = try XCTUnwrap(window.activePathDialog)
        XCTAssertEqual(String(cString: gtk_native_dialog_get_title(dialog.native)), "Save Regions")
        XCTAssertEqual(String(cString: gtk_file_chooser_get_current_name(dialog.chooser)), "regions.reg")
    }

    @MainActor func testCubeSlabQuestionUsesNumericDialogAndSharedOperation() async throws {
        gtk_init()
        let session = try gtkCubeSession()
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        window.present()

        window.commandMenus.activate("tools.extractSlab")

        let dialog = try XCTUnwrap(window.activeNumberDialog)
        XCTAssertEqual(dialog.entries.count, 2)
        XCTAssertEqual(String(cString: gtk_editable_get_text(dialog.entries[0])), "0")
        XCTAssertEqual(String(cString: gtk_editable_get_text(dialog.entries[1])), "2")
        gtk_editable_set_text(dialog.entries[0], "1")
        XCTAssertEqual(gtk_widget_activate(dialog.acceptButton), 1)
        let deadline = Date().addingTimeInterval(2)
        while window.activeNumberDialog != nil && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
        }
        XCTAssertNil(window.activeNumberDialog)

        await session.idle()
        XCTAssertEqual(session.derived?.label, "Slab 1…2 (sum)")
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 8)
    }

    @MainActor func testCubeControlsScrubAndDrivePlayback() throws {
        gtk_init()
        let session = try gtkCubeSession()
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        window.present()

        XCTAssertEqual(gtk_widget_get_visible(UnsafeMutablePointer<GtkWidget>(OpaquePointer(window.cubeControls))), 1)
        gtk_range_set_value(window.planeScale, 2)
        XCTAssertEqual(session.plane, 2)
        XCTAssertEqual(String(cString: gtk_label_get_text(window.planeLabel)), "3 / 3")
        gtk_spin_button_set_value(window.fpsSpin, 30)
        XCTAssertEqual(session.fps, 30)

        XCTAssertEqual(gtk_widget_activate(window.playButton), 1)
        let deadline = Date().addingTimeInterval(2)
        while (!session.playing || session.plane == 2) && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(session.playing)
        XCTAssertNotEqual(session.plane, 2)
        XCTAssertEqual(String(cString: gtk_button_get_label(
            UnsafeMutablePointer<GtkButton>(OpaquePointer(window.playButton))
        )), "Pause")
        _ = session.perform(.setPlaying(false), origin: .user)
    }

    @MainActor func testTableHDUShowsPagedSharedCells() throws {
        gtk_init()
        let session = try gtkTableSession()
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        window.present()
        XCTAssertEqual(gtk_widget_get_visible(window.tablePanel.widget), 0)

        XCTAssertNil(session.perform(.selectHDU(1), origin: .user).failure)
        XCTAssertEqual(gtk_widget_get_visible(window.tablePanel.widget), 1)
        XCTAssertEqual(gtk_widget_get_visible(UnsafeMutablePointer<GtkWidget>(window.imageOverlay)), 0)
        let firstGrid = try XCTUnwrap(window.tablePanel.grid)
        let firstCell = try XCTUnwrap(gtk_grid_get_child_at(firstGrid, 1, 1))
        XCTAssertEqual(String(cString: gtk_label_get_text(OpaquePointer(firstCell))), "0")
        XCTAssertEqual(String(cString: gtk_label_get_text(window.tablePanel.rangeLabel)),
                       "1–100 of 105 rows · 1 columns")

        XCTAssertEqual(gtk_widget_activate(window.tablePanel.nextButton), 1)
        let deadline = Date().addingTimeInterval(2)
        while window.tablePanel.page == 0 && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
        }
        XCTAssertEqual(window.tablePanel.page, 1)
        let secondGrid = try XCTUnwrap(window.tablePanel.grid)
        let secondPageFirstCell = try XCTUnwrap(gtk_grid_get_child_at(secondGrid, 1, 1))
        XCTAssertEqual(String(cString: gtk_label_get_text(OpaquePointer(secondPageFirstCell))), "100")
        XCTAssertEqual(String(cString: gtk_label_get_text(window.tablePanel.rangeLabel)),
                       "101–105 of 105 rows · 1 columns")
    }

    @MainActor func testGTKKeysReachSharedCanvasInteraction() throws {
        gtk_init()
        let session = try gtkCubeSession()
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        window.present()
        let id = try documentWindowID(matching: "theia-gtk-cube.fits — Theia")
        XCTAssertEqual(gtk_widget_grab_focus(UnsafeMutablePointer<GtkWidget>(window.picture)), 1)

        let key = Process()
        key.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
        key.arguments = ["windowfocus", id, "key", "Right"]
        try key.run()
        let deadline = Date().addingTimeInterval(2)
        while (key.isRunning || session.plane == 0) && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
        }
        key.waitUntilExit()
        XCTAssertEqual(key.terminationStatus, 0)
        XCTAssertEqual(session.plane, 1)
    }

    @MainActor func testRegionSaveAndLoadEffectsCompleteOffMainThread() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        session.regions = [Region(shape: .point(.init(x: 1, y: 1)), frame: .image)]
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-regions-\(UUID().uuidString).reg")
        defer { try? FileManager.default.removeItem(at: path) }

        let save = session.perform(.saveRegions, origin: .user)
        guard case .ask(_, let saveRequest) = try XCTUnwrap(save.effects.first) else {
            return XCTFail("Expected a save path request")
        }
        window.handleOutcome(session.perform(.answer(saveRequest, .path(path)), origin: .user))
        let saveDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: path.path) && Date() < saveDeadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        session.regions = []
        let load = session.perform(.loadRegions, origin: .user)
        guard case .ask(_, let loadRequest) = try XCTUnwrap(load.effects.first) else {
            return XCTFail("Expected an open path request")
        }
        window.handleOutcome(session.perform(.answer(loadRequest, .path(path)), origin: .user))
        let loadDeadline = Date().addingTimeInterval(3)
        while session.regions.isEmpty && Date() < loadDeadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(session.regions.count, 1)
    }

    @MainActor func testFractionalScaleAllocatesExactDevicePixels() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }

        window.updateCanvasSize(width: 201, height: 101, scale: 1.5)

        let paintable = try await waitForCanvas(window) {
            $0 != nil && gdk_texture_get_width($0) == 302
        }
        XCTAssertEqual(gdk_texture_get_width(paintable), 302)
        XCTAssertEqual(gdk_texture_get_height(paintable), 152)
        XCTAssertEqual(session.view.viewSizePoints.width, 201)
        XCTAssertEqual(session.view.backingScale, 1.5)
    }

    @MainActor func testRemoteDragUsesReducedTextureAndRefinesOnRelease() async throws {
        let previousSSH = getenv("SSH_CONNECTION").map { String(cString: $0) }
        setenv("SSH_CONNECTION", "client 12345 cluster 22", 1)
        defer {
            if let previousSSH { setenv("SSH_CONNECTION", previousSSH, 1) }
            else { unsetenv("SSH_CONNECTION") }
        }

        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let session = DocumentSession(url: fileURL,
                                      file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil
        ), 1)
        let bridge = GTKMainLoopBridge()
        XCTAssertTrue(bridge.install())
        defer { bridge.remove() }
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }
        window.present()
        let picture = UnsafeMutablePointer<GtkWidget>(window.picture)
        let layoutDeadline = Date().addingTimeInterval(2)
        while gtk_widget_get_width(picture) == 0 && Date() < layoutDeadline {
            _ = g_main_context_iteration(nil, 0)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let fullTexture = try await waitForCanvas(window, using: bridge, timeout: 15) {
            $0 != nil
        }
        let fullWidth = Int(gdk_texture_get_width(fullTexture))
        XCTAssertGreaterThan(fullWidth, 0)

        let initialCentre = session.view.transform.centre
        XCTAssertTrue(GTKDisplayPolicy.isRemoteDisplay(
            environment: ProcessInfo.processInfo.environment
        ))
        window.beginDrag(at: SIMD2(Double(gtk_widget_get_width(picture)) / 2,
                                   Double(gtk_widget_get_height(picture)) / 2),
                         button: .primary)
        window.updateDrag(offsetX: 40, offsetY: 20)
        var previewWidth: Int?
        var expectedPreviewWidth: Int?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            let pixels = Int((session.view.viewSizePoints.width * session.view.backingScale).rounded())
            let expected = 1 + (pixels - 1) / 4
            if let texture = gtk_picture_get_paintable(window.picture),
               gdk_texture_get_width(texture) == expected {
                previewWidth = Int(gdk_texture_get_width(texture))
                expectedPreviewWidth = expected
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(previewWidth, expectedPreviewWidth,
                       "remote drag should show a quarter-resolution texture")
        XCTAssertNotNil(previewWidth, "remote drag should show a reduced texture")
        window.endDrag(offsetX: 40, offsetY: 20)
        XCTAssertNotEqual(session.view.transform.centre, initialCentre,
                          "the drag must move this document")
        let refinedWidth = Int((session.view.viewSizePoints.width * session.view.backingScale).rounded())
        _ = try await waitForCanvas(window, using: bridge, timeout: 15) {
            $0 != nil && gdk_texture_get_width($0) == refinedWidth
        }
    }

    @MainActor func testCanvasTracksAllocatedWindowSize() async throws {
        gtk_init()
        let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"))
        let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
        let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
        let window = GTKDocumentWindow(application: application, session: session)
        defer { gtk_window_destroy(window.widget) }

        window.present()
        var identifier: String?
        let searchDeadline = Date().addingTimeInterval(2)
        while identifier == nil && Date() < searchDeadline {
            _ = g_main_context_iteration(nil, 0)
            let search = Process()
            search.executableURL = URL(fileURLWithPath: "/usr/bin/xwininfo")
            search.arguments = ["-root", "-tree"]
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C.utf8"
            search.environment = environment
            let output = Pipe()
            search.standardOutput = output
            try search.run()
            search.waitUntilExit()
            if search.terminationStatus == 0 {
                identifier = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .split(separator: "\n")
                    .first(where: { $0.contains("uint8_simple.fits — Theia") })?
                    .split(whereSeparator: \.isWhitespace).first.map(String.init)
            }
            if identifier == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let windowID = try XCTUnwrap(identifier)
        let pictureWidget = UnsafeMutablePointer<GtkWidget>(window.picture)
        let initialSyncDeadline = Date().addingTimeInterval(2)
        while Date() < initialSyncDeadline {
            _ = g_main_context_iteration(nil, 0)
            if session.view.viewSizePoints.width == Double(gtk_widget_get_width(pictureWidget)) {
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let initialWidth = gtk_widget_get_width(pictureWidget)
        let initialHeight = gtk_widget_get_height(pictureWidget)
        let image = try XCTUnwrap(session.displayed)
        XCTAssertEqual(session.view.transform.scale,
                       min(Double(initialWidth) / Double(image.width),
                           Double(initialHeight) / Double(image.height)), accuracy: 1e-6)
        let resize = Process()
        resize.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
        resize.arguments = ["windowsize", windowID, "1200", "780"]
        try resize.run()
        resize.waitUntilExit()
        XCTAssertEqual(resize.terminationStatus, 0)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            let width = gtk_widget_get_width(pictureWidget)
            if width > initialWidth, session.view.viewSizePoints.width == Double(width) { break }
        }

        let allocatedWidth = gtk_widget_get_width(pictureWidget)
        XCTAssertGreaterThan(allocatedWidth, initialWidth)
        XCTAssertEqual(session.view.viewSizePoints.width, Double(allocatedWidth))
        let texture = try await waitForCanvas(window) {
            $0 != nil && gdk_texture_get_width($0) == allocatedWidth
        }
        XCTAssertEqual(gdk_texture_get_width(texture), allocatedWidth)
    }

    func testDestroyNotifiesOwnerOnce() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"))
            let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
            let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
            defer { g_object_unref(UnsafeMutableRawPointer(application)) }
            XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
            var destroyCount = 0
            let window = GTKDocumentWindow(application: application, session: session, onDestroy: {
                destroyCount += 1
            })

            window.present()
            gtk_window_destroy(window.widget)
            _ = g_main_context_iteration(nil, 0)
            session.view.colorMap = .viridis
            XCTAssertEqual(destroyCount, 1)
        }
    }

    func testSelectingHDURowUpdatesSharedSession() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "multi_hdu", withExtension: "fits", subdirectory: "Fixtures"))
            let file = try FITSFile(data: Data(contentsOf: fileURL))
            XCTAssertGreaterThan(file.hdus.count, 1)
            let session = DocumentSession(url: fileURL, file: file)
            let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
            defer { g_object_unref(UnsafeMutableRawPointer(application)) }
            XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
            let window = GTKDocumentWindow(application: application, session: session)
            defer { gtk_window_destroy(window.widget) }

            let target = session.hdu == 0 ? 1 : 0
            let row = try XCTUnwrap(gtk_list_box_get_row_at_index(window.hduList, gint(target)))
            gtk_list_box_select_row(window.hduList, row)
            XCTAssertEqual(session.hdu, target)
            let fitButton = try XCTUnwrap(window.viewButtons["view.fit"])
            XCTAssertEqual(gtk_widget_get_sensitive(fitButton), session.displayed == nil ? 0 : 1)

            _ = session.perform(.selectHDU(session.hdu == 0 ? 1 : 0), origin: .script)
            XCTAssertEqual(
                gtk_list_box_row_get_index(try XCTUnwrap(gtk_list_box_get_selected_row(window.hduList))),
                gint(session.hdu)
            )
            XCTAssertEqual(gtk_widget_get_sensitive(fitButton), session.displayed == nil ? 0 : 1)
        }
    }

    func testViewButtonRunsSharedCommand() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"))
            let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
            let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
            defer { g_object_unref(UnsafeMutableRawPointer(application)) }
            XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
            let window = GTKDocumentWindow(application: application, session: session)
            defer { gtk_window_destroy(window.widget) }

            window.present()
            _ = session.perform(.actualSize, origin: .user)
            XCTAssertEqual(session.view.transform.scale, 1)
            let fitButton = try XCTUnwrap(window.viewButtons["view.fit"])
            XCTAssertEqual(gtk_widget_get_realized(fitButton), 1)
            XCTAssertEqual(gtk_widget_activate(fitButton), 1)
            let deadline = Date().addingTimeInterval(2)
            while session.view.transform.scale == 1 && Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            XCTAssertNotEqual(session.view.transform.scale, 1)
        }
    }

    func testMouseWheelZoomsSharedViewport() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
            let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
            defer { g_object_unref(UnsafeMutableRawPointer(application)) }
            XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
            let window = GTKDocumentWindow(application: application, session: session)
            defer { gtk_window_destroy(window.widget) }
            window.present()
            let id = try documentWindowID()
            for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }
            let initialScale = session.view.transform.scale
            let (x, y) = canvasCenter(in: window)

            let wheel = Process()
            wheel.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
            wheel.arguments = [
                "mousemove", "--window", id, String(x), String(y), "sleep", "0.1", "click", "4",
            ]
            try wheel.run()
            let deadline = Date().addingTimeInterval(2)
            while (wheel.isRunning || session.view.transform.scale == initialScale) && Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            wheel.waitUntilExit()
            XCTAssertEqual(wheel.terminationStatus, 0)
            XCTAssertGreaterThan(session.view.transform.scale, initialScale * 1.1)
        }
    }

    func testMouseMotionUpdatesSharedCursorAndStatus() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
            let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
            defer { g_object_unref(UnsafeMutableRawPointer(application)) }
            XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
            let window = GTKDocumentWindow(application: application, session: session)
            defer { gtk_window_destroy(window.widget) }
            window.present()
            let id = try documentWindowID()
            let picture = UnsafeMutablePointer<GtkWidget>(window.picture)
            let layoutDeadline = Date().addingTimeInterval(2)
            while Date() < layoutDeadline {
                _ = g_main_context_iteration(nil, 0)
                if gtk_widget_get_width(picture) > 0,
                   session.view.viewSizePoints.width == Double(gtk_widget_get_width(picture)) {
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let initialCanvasWidth = gtk_widget_get_width(picture)
            let (x, y) = canvasCenter(in: window)

            let motion = Process()
            motion.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
            motion.arguments = ["mousemove", "--window", id, String(x), String(y)]
            try motion.run()
            let deadline = Date().addingTimeInterval(2)
            while (motion.isRunning || session.cursor == nil) && Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            motion.waitUntilExit()
            XCTAssertEqual(motion.terminationStatus, 0)
            let cursor = try XCTUnwrap(session.cursor)
            let status = String(cString: gtk_label_get_text(window.statusLabel))
            XCTAssertTrue(status.contains("\(cursor.fitsX), \(cursor.fitsY)"))
            for _ in 0..<20 {
                _ = g_main_context_iteration(nil, 0)
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertEqual(gtk_widget_get_width(picture), initialCanvasWidth)
        }
    }

    func testMouseDragPansSharedViewport() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            let session = DocumentSession(url: fileURL, file: try FITSFile(data: Data(contentsOf: fileURL)))
            let application = gtk_application_new("cl.jvines.theia.tests", GApplicationFlags(rawValue: 1 << 5))!
            defer { g_object_unref(UnsafeMutableRawPointer(application)) }
            XCTAssertEqual(g_application_register(UnsafeMutablePointer<GApplication>(OpaquePointer(application)), nil, nil), 1)
            let window = GTKDocumentWindow(application: application, session: session)
            defer { gtk_window_destroy(window.widget) }
            window.present()
            let id = try documentWindowID()
            for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }
            let initialCentre = session.view.transform.centre
            let (x, y) = canvasCenter(in: window)
            let endX = String(x + 40)
            let endY = String(y + 20)

            let drag = Process()
            drag.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
            drag.arguments = [
                "mousemove", "--window", id, String(x), String(y), "sleep", "0.1",
                "mousedown", "1", "sleep", "0.1",
                "mousemove", "--window", id, endX, endY, "sleep", "0.1", "mouseup", "1",
            ]
            try drag.run()
            let deadline = Date().addingTimeInterval(2)
            while (drag.isRunning || session.view.transform.centre == initialCentre) && Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            drag.waitUntilExit()
            XCTAssertEqual(drag.terminationStatus, 0)

            XCTAssertNotEqual(session.view.transform.centre, initialCentre)
        }
    }
}
