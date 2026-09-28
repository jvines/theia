import CGtk4
import Foundation

/// The user's GTK recent-file database, filtered to FITS paths Theia can open.
@MainActor final class GTKRecentFiles {
    private let manager: UnsafeMutablePointer<GtkRecentManager>
    private let extensions: Set<String> = ["fits", "fit", "fts", "fz"]

    init() {
        if g_get_application_name() == nil { g_set_application_name("Theia") }
        manager = gtk_recent_manager_get_default()!
    }

    func record(_ url: URL) {
        guard url.isFileURL else { return }
        url.absoluteString.withCString { uri in
            "image/fits".withCString { mime in
                "Theia".withCString { name in
                    "theia-gtk %f".withCString { command in
                        var data = GtkRecentData(
                            display_name: nil, description: nil,
                            mime_type: UnsafeMutablePointer(mutating: mime),
                            app_name: UnsafeMutablePointer(mutating: name),
                            app_exec: UnsafeMutablePointer(mutating: command),
                            groups: nil, is_private: 0
                        )
                        _ = gtk_recent_manager_add_full(manager, uri, &data)
                    }
                }
            }
        }
    }

    func urls(limit: Int = 10) -> [URL] {
        guard let items = gtk_recent_manager_get_items(manager) else { return [] }
        defer { g_list_free(items) }
        var result: [URL] = []
        var node: UnsafeMutablePointer<GList>? = items
        while let current = node {
            if let raw = current.pointee.data {
                let info = OpaquePointer(raw)
                if let uri = gtk_recent_info_get_uri(info),
                   let url = URL(string: String(cString: uri)),
                   url.isFileURL, extensions.contains(url.pathExtension.lowercased()),
                   result.count < limit {
                    result.append(url)
                }
                gtk_recent_info_unref(info)
            }
            node = current.pointee.next
        }
        return result
    }
}
