import CGtk4
import Foundation
import XCTest
@testable import TheiaGTK

final class GTKTranslationsTests: XCTestCase {
    func testBundledCatalogDirectoryRebindsGtkDomains() {
        let domains = ["gtk40", "glib20", "gdk-pixbuf"]
        let original = domains.map { domain in
            String(cString: bindtextdomain(domain, nil)!)
        }
        defer {
            for (domain, directory) in zip(domains, original) {
                _ = bindtextdomain(domain, directory)
            }
        }

        let directory = "/opt/theia/share/locale"
        GTKTranslations.configure(environment: ["THEIA_LOCALE_DIR": directory])
        for domain in domains {
            XCTAssertEqual(String(cString: bindtextdomain(domain, nil)!), directory)
        }
    }
}
