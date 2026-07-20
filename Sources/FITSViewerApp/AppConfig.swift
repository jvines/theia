import Foundation

/// Application-wide build configuration.
///
/// To ship a release build, set `isBeta = false` here and rebuild.
/// No compiler flags or Package.swift changes are required.
enum AppConfig {
    /// When `true`, the app displays a "BETA" watermark over the image view and
    /// labels the version string in the About panel as "(Beta)".
    /// Flip to `false` before cutting a production release.
    static let isBeta: Bool = false
}
