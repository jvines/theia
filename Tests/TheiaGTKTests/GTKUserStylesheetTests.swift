import CGtk4
import Foundation
import Glibc
import XCTest
@testable import TheiaGTK

final class GTKUserStylesheetTests: XCTestCase {
    /// ergonOS links ~/.config/gtk-4.0/gtk.css to a file it renders, holds
    /// both colour schemes in @media blocks, and replaces the file by rename
    /// when the palette changes.
    @MainActor func testRunningAppFollowsAPaletteRenamedOverTheLinkedStylesheet() async throws {
        gtk_init()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-stylesheet-\(UUID().uuidString)")
        let rendered = root.appendingPathComponent("ergon/gtk/gtk4.css")
        let link = root.appendingPathComponent("config/gtk-4.0/gtk.css")
        try FileManager.default.createDirectory(at: rendered.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func palette(light: String, dark: String) -> String {
            "@media (prefers-color-scheme: light) { .theia-palette-probe { color: \(light); } }\n"
                + "@media (prefers-color-scheme: dark) { .theia-palette-probe { color: \(dark); } }\n"
        }
        try palette(light: "#ff0000", dark: "#0000ff").write(to: rendered, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rendered)

        let settings = try XCTUnwrap(gtk_settings_get_default())
        let previousScheme = colorScheme(of: settings)
        defer { setColorScheme(previousScheme, on: settings) }
        setColorScheme(GTK_INTERFACE_COLOR_SCHEME_DARK, on: settings)

        let stylesheet = GTKUserStylesheet(path: link.path)
        stylesheet.start()
        defer { stylesheet.stop() }
        let window = gtk_window_new()!
        defer { gtk_window_destroy(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window))) }
        let label = gtk_label_new("probe")!
        gtk_widget_add_css_class(label, "theia-palette-probe")
        gtk_window_set_child(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)), label)
        gtk_window_present(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)))

        let next = rendered.deletingLastPathComponent().appendingPathComponent("gtk4.css.ergon-render")
        try palette(light: "#00ff00", dark: "#ffff00").write(to: next, atomically: false, encoding: .utf8)
        XCTAssertEqual(rename(next.path, rendered.path), 0)
        let followedPalette = try await waitForColor(of: label, red: 1, green: 1, blue: 0)
        XCTAssertTrue(followedPalette, "the new palette's dark block did not reach the running app")

        setColorScheme(GTK_INTERFACE_COLOR_SCHEME_LIGHT, on: settings)
        let followedScheme = try await waitForColor(of: label, red: 0, green: 1, blue: 0)
        XCTAssertTrue(followedScheme, "a light/dark flip did not move the reloaded palette")
    }

    /// GTK keeps the stylesheet it read at launch. A rule only the launch
    /// palette has must not outlive it. GTK reads the file during gtk_init,
    /// so this runs the next test in a child process with its own config.
    func testLaunchPaletteRuleDoesNotOutliveItsFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-gtk-launch-stylesheet-\(UUID().uuidString)")
        let rendered = root.appendingPathComponent("ergon/gtk/gtk4.css")
        let link = root.appendingPathComponent("config/gtk-4.0/gtk.css")
        try FileManager.default.createDirectory(at: rendered.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ".theia-launch-only { color: #ff0000; }\n".write(to: rendered, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rendered)

        let child = Process()
        child.executableURL = try XCTUnwrap(Bundle.main.executableURL)
        child.arguments = ["TheiaGTKTests.GTKUserStylesheetTests/testLaunchPaletteChildProcess"]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["THEIA_TEST_STYLESHEET_ROOT"] = root.path
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("Executed 1 test, with 0 failures"), log)
    }

    @MainActor func testLaunchPaletteChildProcess() async throws {
        guard let root = ProcessInfo.processInfo.environment["THEIA_TEST_STYLESHEET_ROOT"] else {
            throw XCTSkip("runs in its own process from testLaunchPaletteRuleDoesNotOutliveItsFile")
        }
        gtk_init()
        let rendered = URL(fileURLWithPath: root).appendingPathComponent("ergon/gtk/gtk4.css")
        let stylesheet = GTKUserStylesheet()
        XCTAssertEqual(stylesheet.path, URL(fileURLWithPath: root).appendingPathComponent("config/gtk-4.0/gtk.css").path)
        stylesheet.start()
        defer { stylesheet.stop() }
        let settings = try XCTUnwrap(gtk_settings_get_default())
        let reducedMotion = reducedMotion(of: settings)

        let window = gtk_window_new()!
        defer { gtk_window_destroy(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window))) }
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        let launchOnly = gtk_label_new("launch")!
        let nextOnly = gtk_label_new("next")!
        gtk_widget_add_css_class(launchOnly, "theia-launch-only")
        gtk_widget_add_css_class(nextOnly, "theia-next-only")
        gtk_box_append(UnsafeMutablePointer<GtkBox>(OpaquePointer(box)), launchOnly)
        gtk_box_append(UnsafeMutablePointer<GtkBox>(OpaquePointer(box)), nextOnly)
        gtk_window_set_child(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)), box)
        gtk_window_present(UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)))
        let launched = try await waitForColor(of: launchOnly, red: 1, green: 0, blue: 0)
        XCTAssertTrue(launched, "GTK did not load the launch palette")

        let next = rendered.deletingLastPathComponent().appendingPathComponent("gtk4.css.ergon-render")
        try """
            @media (prefers-color-scheme: light) { .theia-next-only { color: #00ff00; } }
            @media (prefers-color-scheme: dark) { .theia-next-only { color: #ffff00; } }

            """.write(to: next, atomically: false, encoding: .utf8)
        XCTAssertEqual(rename(next.path, rendered.path), 0)
        let switched = try await waitForColor(of: nextOnly, red: 0, green: 1, blue: 0)
        XCTAssertTrue(switched, "the next palette did not reach the running app")
        var color = GdkRGBA()
        gtk_widget_get_color(launchOnly, &color)
        XCTAssertFalse(color.red == 1 && color.green == 0 && color.blue == 0,
                       "the launch palette's rule outlived its file")
        XCTAssertEqual(self.reducedMotion(of: settings), reducedMotion)

        let previousScheme = colorScheme(of: settings)
        defer { setColorScheme(previousScheme, on: settings) }
        setColorScheme(GTK_INTERFACE_COLOR_SCHEME_DARK, on: settings)
        let followedScheme = try await waitForColor(of: nextOnly, red: 1, green: 1, blue: 0)
        XCTAssertTrue(followedScheme, "a light/dark flip did not move the reloaded palette")
    }

    @MainActor private func waitForColor(of widget: UnsafeMutablePointer<GtkWidget>,
                                         red: Float, green: Float, blue: Float) async throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        var color = GdkRGBA()
        while Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            gtk_widget_get_color(widget, &color)
            if color.red == red, color.green == green, color.blue == blue { return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func colorScheme(of settings: OpaquePointer) -> GtkInterfaceColorScheme {
        var value = GValue()
        g_value_init(&value, gtk_interface_color_scheme_get_type())
        defer { g_value_unset(&value) }
        g_object_get_property(UnsafeMutablePointer<GObject>(settings),
                              "gtk-interface-color-scheme", &value)
        return GtkInterfaceColorScheme(rawValue: UInt32(g_value_get_enum(&value)))
    }

    private func reducedMotion(of settings: OpaquePointer) -> gint {
        var value = GValue()
        g_value_init(&value, gtk_reduced_motion_get_type())
        defer { g_value_unset(&value) }
        g_object_get_property(UnsafeMutablePointer<GObject>(settings),
                              "gtk-interface-reduced-motion", &value)
        return g_value_get_enum(&value)
    }

    private func setColorScheme(_ scheme: GtkInterfaceColorScheme,
                                on settings: OpaquePointer) {
        var value = GValue()
        g_value_init(&value, gtk_interface_color_scheme_get_type())
        defer { g_value_unset(&value) }
        g_value_set_enum(&value, gint(scheme.rawValue))
        g_object_set_property(UnsafeMutablePointer<GObject>(settings),
                              "gtk-interface-color-scheme", &value)
    }
}
