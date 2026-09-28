import Foundation
import Glibc

enum GTKDisplayPolicy {
    /// GTK reads GSK_RENDERER during startup, before any windows exist.
    static func configure(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard shouldUseCairo(environment: environment) else { return }
        setenv("GSK_RENDERER", "cairo", 1)
    }

    static func shouldUseCairo(environment: [String: String]) -> Bool {
        // GSK_RENDERER is the explicit diagnostic override, including on forwarded displays.
        if environment["GSK_RENDERER"] != nil { return false }
        if environment["SSH_CONNECTION"]?.isEmpty == false ||
           environment["SSH_CLIENT"]?.isEmpty == false ||
           environment["WAYPIPE_DISPLAY"]?.isEmpty == false { return true }
        guard let display = environment["DISPLAY"],
              let colon = display.lastIndex(of: ":") else { return false }
        let host = String(display[..<colon])
        if host.isEmpty || host == "unix" { return false }
        let displayNumber = Int(display[display.index(after: colon)...].prefix(while: \.isNumber)) ?? 0
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return displayNumber >= 10
        }
        return true
    }
}
