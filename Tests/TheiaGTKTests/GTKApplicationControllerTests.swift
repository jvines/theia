import CGtk4
import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKApplicationControllerTests: XCTestCase {
    @MainActor func testRemoteBytesOpenAndReuseDocumentWindow() throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let url = try XCTUnwrap(URL(string: "ssh://jose@cluster.example/data/image.fits"))
        let bytes = try Data(contentsOf: fixture)
        let controller = GTKApplicationController(paths: [])
        defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
        ), 1)
        let first = try controller.open(url: url, remoteData: bytes)
        defer { gtk_window_destroy(first.widget) }
        XCTAssertEqual(first.session.url, url)
        XCTAssertEqual(first.session.file.hdus.count, 1)
        let again = try controller.open(url: url, remoteData: bytes)
        XCTAssertTrue(first === again)
        XCTAssertEqual(controller.documentWindowCount, 1)
        first.commandMenus.activate("file.openRemote")
        let dialog = try XCTUnwrap(controller.remoteDialog)
        gtk_window_destroy(dialog.widget)
        XCTAssertNil(controller.remoteDialog)
    }

    @MainActor func testRemoteCubeAndTableUseNativeDocumentControls() async throws {
        gtk_init()
        func header(_ cards: [String]) -> Data {
            let text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
            return Data(text.padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
        }
        let cube = header([
            "SIMPLE  =                    T", "BITPIX  =                    8",
            "NAXIS   =                    3", "NAXIS1  =                    1",
            "NAXIS2  =                    1", "NAXIS3  =                    3",
            "EXTEND  =                    T", "END",
        ]) + Data([2, 3, 5]) + Data(repeating: 0, count: 2877)
        let tableHeader = header([
            "XTENSION= 'BINTABLE'", "BITPIX  =                    8",
            "NAXIS   =                    2", "NAXIS1  =                    1",
            "NAXIS2  =                    1", "PCOUNT  =                    0",
            "GCOUNT  =                    1", "TFIELDS =                    1",
            "TTYPE1  = 'id'", "TFORM1  = '1B'", "END",
        ])
        let bytes = cube + tableHeader + Data([42]) + Data(repeating: 0, count: 2879)
        let url = try XCTUnwrap(URL(string: "ssh://jose@cluster.example/data/cube-table.fits"))
        let controller = GTKApplicationController(paths: [])
        defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
        ), 1)
        let window = try controller.open(url: url, remoteData: bytes)
        defer { gtk_window_destroy(window.widget) }
        XCTAssertEqual(window.session.url, url)
        XCTAssertEqual(window.session.facts[0].planeCount, 3)
        XCTAssertEqual(gtk_widget_get_visible(
            UnsafeMutablePointer<GtkWidget>(OpaquePointer(window.cubeControls))
        ), 1)
        window.session.selectPlane(2)
        XCTAssertEqual(window.session.displayed?.physicalValue(x: 0, y: 0), 5)
        window.session.selectHDU(1)
        XCTAssertEqual(gtk_widget_get_visible(window.tablePanel.widget), 1)
        XCTAssertEqual(window.tablePanel.table?.displayValue(row: 0, column: 0), "42")
    }

    @MainActor func testWorkspaceSyncAndStackToolsUseOpenGTKDocuments() async throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-second-\(UUID().uuidString).fits")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let controller = GTKApplicationController(paths: [])
        defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
        ), 1)
        let first = try controller.open(path: fixture.path)
        let second = try controller.open(path: copy.path)
        defer {
            gtk_window_destroy(first.widget)
            gtk_window_destroy(second.widget)
        }

        XCTAssertEqual(first.commandMenus.sectionCount, 14)
        XCTAssertTrue(first.commandMenus.isEnabled("tools.stack.sum"))
        first.commandMenus.activate("sync.colormap")
        XCTAssertEqual(first.commandMenus.title(for: "sync.colormap"), "✓ Match colormap")
        first.session.view.colorMap = .viridis
        XCTAssertEqual(second.session.view.colorMap, .viridis)

        first.commandMenus.activate("tools.stack.sum")
        await first.session.idle()
        XCTAssertNotNil(first.session.derived)
    }

    func testOpeningPathReusesDocumentWindowAndClosesWelcome() async throws {
        try await MainActor.run {
            gtk_init()
            let fileURL = try XCTUnwrap(Bundle.module.url(
                forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
            ))
            let controller = GTKApplicationController(paths: [])
            defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
            XCTAssertEqual(g_application_register(
                UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
            ), 1)
            controller.showWelcomeWindow()
            XCTAssertNotNil(controller.welcomeWindow)
            let document = try controller.open(path: fileURL.path)
            XCTAssertEqual(controller.documentWindowCount, 1)
            XCTAssertNil(controller.welcomeWindow)
            let reopened = try controller.open(path: fileURL.path)
            XCTAssertTrue(document === reopened)
            XCTAssertEqual(controller.documentWindowCount, 1)
            gtk_window_destroy(document.widget)
            XCTAssertEqual(controller.documentWindowCount, 0)
        }
    }

    @MainActor func testAppAndHelpMenusOpenIndependentWindows() async throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let controller = GTKApplicationController(paths: [])
        defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
        ), 1)
        let document = try controller.open(path: fixture.path)
        defer { gtk_window_destroy(document.widget) }

        document.commandMenus.activate("app.about")
        let about = try XCTUnwrap(controller.infoWindows["about"])
        XCTAssertEqual(String(cString: gtk_window_get_title(about.widget)), "About Theia")
        document.commandMenus.activate("app.about")
        XCTAssertTrue(about === controller.infoWindows["about"])

        document.commandMenus.activate("help.scriptingReference")
        let scripting = try XCTUnwrap(controller.infoWindows["scripting"])
        XCTAssertEqual(String(cString: gtk_window_get_title(scripting.widget)),
                       "HTTP Scripting Reference")
        document.commandMenus.activate("help.onboarding")
        let onboarding = try XCTUnwrap(controller.infoWindows["onboarding"])
        XCTAssertEqual(String(cString: gtk_window_get_title(onboarding.widget)),
                       "Welcome to Theia")
        gtk_window_destroy(about.widget)
        XCTAssertNil(controller.infoWindows["about"])
        gtk_window_destroy(scripting.widget)
        gtk_window_destroy(onboarding.widget)
    }

    @MainActor func testChangedFITSOffersRestoreBeforeApplyingSavedState() async throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-stale-dialog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("source.fits")
        let data = try Data(contentsOf: fixture)
        try data.write(to: fileURL)
        let appPaths = AppPaths(platform: .linux, homeDirectory: root,
                                environment: ["XDG_STATE_HOME": root.path])
        let savedSession = DocumentSession(url: fileURL, file: try FITSFile(data: data))
        let persistence = GTKSessionPersistence(session: savedSession, fileData: data, paths: appPaths)
        persistence.start()
        _ = savedSession.perform(.setLevels(min: 10, max: 40), origin: .user)
        persistence.close()
        var changed = data
        let note = "COMMENT GTK dialog check".padding(toLength: 80, withPad: " ", startingAt: 0)
        changed.replaceSubrange(800..<880, with: note.utf8)
        try changed.write(to: fileURL)

        let controller = GTKApplicationController(paths: [], appPaths: appPaths)
        defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
        ), 1)
        let document = try controller.open(path: fileURL.path)
        defer { gtk_window_destroy(document.widget) }
        let dialog = try XCTUnwrap(controller.staleDialogs[document.session.id])
        XCTAssertNotEqual(document.session.view.vmin, 10)
        _ = gtk_widget_activate(dialog.restoreButton)
        let deadline = Date().addingTimeInterval(1)
        while controller.staleDialogs[document.session.id] != nil && Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
        }
        XCTAssertNil(controller.staleDialogs[document.session.id])
        XCTAssertEqual(document.session.view.vmin, 10)
        XCTAssertEqual(document.session.view.vmax, 40)
    }

    @MainActor func testSettingsMenuPersistsDefaultsForNextDocument() async throws {
        gtk_init()
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "uint8_simple", withExtension: "fits", subdirectory: "Fixtures"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-settings-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appPaths = AppPaths(platform: .linux, homeDirectory: root,
                                environment: ["XDG_CONFIG_HOME": root.path,
                                              "XDG_STATE_HOME": root.path])
        let controller = GTKApplicationController(paths: [], appPaths: appPaths)
        defer { g_object_unref(UnsafeMutableRawPointer(controller.application)) }
        XCTAssertEqual(g_application_register(
            UnsafeMutablePointer<GApplication>(OpaquePointer(controller.application)), nil, nil
        ), 1)
        let first = try controller.open(path: fixture.path)
        defer { gtk_window_destroy(first.widget) }
        first.commandMenus.activate("app.settings")
        let settings = try XCTUnwrap(controller.settingsWindow)
        settings.set(group: "stretch", value: "asinh")
        settings.set(group: "colormap", value: "viridis")
        let secondURL = root.appendingPathComponent("second.fits")
        try FileManager.default.copyItem(at: fixture, to: secondURL)
        let second = try controller.open(path: secondURL.path)
        defer { gtk_window_destroy(second.widget) }
        XCTAssertEqual(second.session.view.stretch, .asinh)
        XCTAssertEqual(second.session.view.colorMap, .viridis)
        gtk_window_destroy(settings.widget)
        XCTAssertNil(controller.settingsWindow)
    }
}
