import SwiftUI

/// Shared visual identity. Defaults to a deep-violet accent that matches the icon's
/// night-sky palette without fighting macOS's chrome.
enum AppTheme {
    static let accent = Color(red: 0.42, green: 0.32, blue: 0.78)
    static let accentSoft = Color(red: 0.42, green: 0.32, blue: 0.78).opacity(0.18)
    static let regionDefaultHex = "#6B52C6"
}
