import FITSCore
import Foundation
import TheiaKit

/// Typed Linux preferences stored at the XDG config path.
@MainActor final class GTKPreferences {
    private struct Record: Codable {
        var stretch: String?
        var colorMap: String?
        var zscaleContrast: Double?
        var pixelTableSize: Int?
        var regionColor: String?
        var readoutFrame: String?
        var hasSeenOnboarding: Bool?
        var xpaVisibility: String?

        enum CodingKeys: String, CodingKey {
            case stretch = "pref.defaultStretch"
            case colorMap = "pref.defaultColorMap"
            case zscaleContrast = "pref.zscaleContrast"
            case pixelTableSize = "pref.pixelTableSize"
            case regionColor = "pref.regionColor"
            case readoutFrame = "readoutFrame"
            case hasSeenOnboarding = "hasSeenOnboarding"
            case xpaVisibility = "pref.xpaVisibility"
        }
    }

    let fileURL: URL
    private var record = Record()
    private(set) var warningMessage: String?

    init(paths: AppPaths = AppPaths(platform: .linux)) {
        fileURL = paths.preferencesFile!
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: fileURL))
        } catch {
            warningMessage = error.localizedDescription
        }
    }

    var defaultStretch: ImageStretch {
        record.stretch.flatMap(ImageStretch.init(rawValue:)) ?? PreferenceKeys.DefaultStretch.defaultValue
    }
    var defaultColorMap: ColorMap {
        record.colorMap.flatMap(ColorMap.init(rawValue:)) ?? PreferenceKeys.DefaultColorMap.defaultValue
    }
    var zscaleContrast: Double {
        PreferenceKeys.ZScaleContrast.normalize(
            record.zscaleContrast ?? PreferenceKeys.ZScaleContrast.defaultValue
        )
    }
    var pixelTableSize: Int {
        PreferenceKeys.PixelTableSize.normalize(
            record.pixelTableSize ?? PreferenceKeys.PixelTableSize.defaultValue
        )
    }
    var regionColor: String {
        PreferenceKeys.RegionColor.normalize(
            record.regionColor ?? PreferenceKeys.RegionColor.defaultValue
        )
    }
    var readoutFrame: CelestialFrame {
        record.readoutFrame.flatMap(CelestialFrame.init(rawValue:))
            ?? PreferenceKeys.ReadoutFrame.defaultValue
    }
    var hasSeenOnboarding: Bool {
        record.hasSeenOnboarding ?? PreferenceKeys.HasSeenOnboarding.defaultValue
    }
    var xpaVisibility: XPAVisibility {
        record.xpaVisibility.flatMap(XPAVisibility.init(rawValue:))
            ?? PreferenceKeys.XPAVisibility.defaultValue
    }

    func setDefaultStretch(_ value: ImageStretch) throws {
        try update { $0.stretch = value.rawValue }
    }
    func setDefaultColorMap(_ value: ColorMap) throws {
        try update { $0.colorMap = value.rawValue }
    }
    func setZScaleContrast(_ value: Double) throws {
        try update { $0.zscaleContrast = PreferenceKeys.ZScaleContrast.normalize(value) }
    }
    func setPixelTableSize(_ value: Int) throws {
        try update { $0.pixelTableSize = PreferenceKeys.PixelTableSize.normalize(value) }
    }
    func setRegionColor(_ value: String) throws {
        try update { $0.regionColor = PreferenceKeys.RegionColor.normalize(value) }
    }
    func setReadoutFrame(_ value: CelestialFrame) throws {
        try update { $0.readoutFrame = value.rawValue }
    }
    func setHasSeenOnboarding(_ value: Bool) throws {
        try update { $0.hasSeenOnboarding = value }
    }
    func setXPAVisibility(_ value: XPAVisibility) throws {
        try update { $0.xpaVisibility = value.rawValue }
    }

    private func update(_ change: (inout Record) -> Void) throws {
        var next = record
        change(&next)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        record = next
        warningMessage = nil
    }
}
