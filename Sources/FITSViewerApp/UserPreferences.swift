import Foundation
import FITSCore
import TheiaKit

/// UserDefaults-backed app preferences applied to newly opened documents.
/// Existing documents keep their current state; load a file to see the new defaults.
final class UserPreferences {
    static let shared = UserPreferences()

    private enum Key {
        static let defaultStretch     = "pref.defaultStretch"
        static let defaultColorMap    = "pref.defaultColorMap"
        static let zscaleContrast     = "pref.zscaleContrast"
        static let pixelTableSize     = "pref.pixelTableSize"
        static let regionColor        = "pref.regionColor"
    }

    var defaultStretch: ImageStretch {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.defaultStretch) ?? ImageStretch.linear.rawValue
            return ImageStretch(rawValue: raw) ?? .linear
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.defaultStretch) }
    }

    var defaultColorMap: ColorMap {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.defaultColorMap) ?? ColorMap.gray.rawValue
            return ColorMap(rawValue: raw) ?? .gray
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.defaultColorMap) }
    }

    /// ZScale contrast parameter; lower → wider effective range.
    var zscaleContrast: Double {
        get {
            let v = UserDefaults.standard.double(forKey: Key.zscaleContrast)
            return v == 0 ? 0.25 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.zscaleContrast) }
    }

    var pixelTableSize: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Key.pixelTableSize)
            return v == 0 ? 7 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.pixelTableSize) }
    }

    /// DS9 colour name for newly drawn regions.
    var regionColor: String {
        get { RegionList.color(UserDefaults.standard.string(forKey: Key.regionColor)) }
        set { UserDefaults.standard.set(RegionList.color(newValue), forKey: Key.regionColor) }
    }
}
