import Foundation
import FITSCore
import TheiaKit

/// UserDefaults-backed app preferences. Display defaults apply to new documents;
/// ZScale contrast is read again whenever a document computes new levels.
final class UserPreferences {
    static let shared = UserPreferences()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var defaultStretch: ImageStretch {
        get {
            let key = PreferenceKeys.DefaultStretch.self
            return defaults.string(forKey: key.name).flatMap(ImageStretch.init(rawValue:)) ?? key.defaultValue
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKeys.DefaultStretch.name) }
    }

    var defaultColorMap: ColorMap {
        get {
            let key = PreferenceKeys.DefaultColorMap.self
            return defaults.string(forKey: key.name).flatMap(ColorMap.init(rawValue:)) ?? key.defaultValue
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKeys.DefaultColorMap.name) }
    }

    /// ZScale contrast parameter; lower → wider effective range.
    var zscaleContrast: Double {
        get {
            let key = PreferenceKeys.ZScaleContrast.self
            guard defaults.object(forKey: key.name) != nil else { return key.defaultValue }
            return key.normalize(defaults.double(forKey: key.name))
        }
        set {
            defaults.set(PreferenceKeys.ZScaleContrast.normalize(newValue),
                         forKey: PreferenceKeys.ZScaleContrast.name)
        }
    }

    var pixelTableSize: Int {
        get {
            let key = PreferenceKeys.PixelTableSize.self
            guard defaults.object(forKey: key.name) != nil else { return key.defaultValue }
            return key.normalize(defaults.integer(forKey: key.name))
        }
        set {
            defaults.set(PreferenceKeys.PixelTableSize.normalize(newValue),
                         forKey: PreferenceKeys.PixelTableSize.name)
        }
    }

    /// DS9 colour name for newly drawn regions.
    var regionColor: String {
        get {
            let key = PreferenceKeys.RegionColor.self
            return key.normalize(defaults.string(forKey: key.name) ?? key.defaultValue)
        }
        set {
            defaults.set(PreferenceKeys.RegionColor.normalize(newValue),
                         forKey: PreferenceKeys.RegionColor.name)
        }
    }

    var readoutFrame: CelestialFrame {
        get {
            let key = PreferenceKeys.ReadoutFrame.self
            return defaults.string(forKey: key.name).flatMap(CelestialFrame.init(rawValue:)) ?? key.defaultValue
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKeys.ReadoutFrame.name) }
    }

    var hasSeenOnboarding: Bool {
        get { defaults.bool(forKey: PreferenceKeys.HasSeenOnboarding.name) }
        set { defaults.set(newValue, forKey: PreferenceKeys.HasSeenOnboarding.name) }
    }
}
