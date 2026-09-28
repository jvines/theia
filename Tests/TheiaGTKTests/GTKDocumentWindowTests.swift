import CGtk4
import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

@MainActor private func documentWindowID() throws -> String {
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
            .first(where: { $0.contains("uint8_simple.fits — Theia") })?
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
    matching predicate: (OpaquePointer?) -> Bool
) async throws -> OpaquePointer {
    let bridge = GTKMainLoopBridge()
    XCTAssertTrue(bridge.install())
    defer { bridge.remove() }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        _ = g_main_context_iteration(nil, 0)
        let paintable = gtk_picture_get_paintable(window.picture)
        if predicate(paintable) { return try XCTUnwrap(paintable) }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    return try XCTUnwrap(nil as OpaquePointer?, "GTK canvas did not finish rendering")
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

final class GTKDocumentWindowTests: XCTestCase {
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

        XCTAssertEqual(window.commandMenus.sectionCount, 9)
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
        let initialWidth = gtk_widget_get_width(pictureWidget)
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
            for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) }
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
