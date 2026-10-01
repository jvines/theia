import CGtk4
import TheiaKit

/// Keyboard shortcuts for the actions behind the GTK menus.
enum GTKShortcuts {
    /// File menu shortcuts the Mac gets from AppKit's standard menus.
    static let open = CommandShortcut(key: "o")
    static let quit = CommandShortcut(key: "q")

    /// The GTK trigger string for a shortcut; the primary modifier is Control.
    static func trigger(for shortcut: CommandShortcut) -> String {
        let scalar = shortcut.key.unicodeScalars.first?.value ?? 0
        let name = gdk_keyval_name(gdk_unicode_to_keyval(scalar)).map { String(cString: $0) }
            ?? shortcut.key
        return "<Control>" + (shortcut.shift ? "<Shift>" : "") + name
    }
}
