import CGtk4
import Foundation

enum GTKTranslations {
    static func configure(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let directory = environment["THEIA_LOCALE_DIR"], !directory.isEmpty else { return }
        for domain in ["gtk40", "glib20", "gdk-pixbuf"] {
            domain.withCString { name in
                directory.withCString { path in
                    _ = bindtextdomain(name, path)
                }
            }
        }
    }
}
