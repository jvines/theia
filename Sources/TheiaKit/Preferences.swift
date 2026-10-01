import FITSCore

/// A typed preference's stable storage name, default, and value validation.
/// Storage adapters decide how values are encoded on each platform.
public protocol PreferenceKey {
    associatedtype Value: Sendable
    static var name: String { get }
    static var defaultValue: Value { get }
    static func normalize(_ value: Value) -> Value
}

public extension PreferenceKey {
    static func normalize(_ value: Value) -> Value { value }
}

public enum PreferenceKeys {
    public enum DefaultStretch: PreferenceKey {
        public static let name = "pref.defaultStretch"
        public static let defaultValue: ImageStretch = .linear
    }

    public enum DefaultColorMap: PreferenceKey {
        public static let name = "pref.defaultColorMap"
        public static let defaultValue: ColorMap = .gray
    }

    public enum ZScaleContrast: PreferenceKey {
        public static let name = "pref.zscaleContrast"
        public static let defaultValue = 0.25

        public static func normalize(_ value: Double) -> Double {
            value.isFinite && (0.05...1).contains(value) ? value : defaultValue
        }
    }

    public enum PixelTableSize: PreferenceKey {
        public static let name = "pref.pixelTableSize"
        public static let defaultValue = 7

        public static func normalize(_ value: Int) -> Int {
            PixelTableModel(size: value).size
        }
    }

    public enum RegionColor: PreferenceKey {
        public static let name = "pref.regionColor"
        public static let defaultValue = RegionList.defaultColor

        public static func normalize(_ value: String) -> String {
            RegionList.color(value)
        }
    }

    public enum ReadoutFrame: PreferenceKey {
        public static let name = "readoutFrame"
        public static let defaultValue: CelestialFrame = .icrs
    }

    public enum HasSeenOnboarding: PreferenceKey {
        public static let name = "hasSeenOnboarding"
        public static let defaultValue = false
    }

    public enum XPAVisibility: PreferenceKey {
        public static let name = "pref.xpaVisibility"
        public static let defaultValue: TheiaKit.XPAVisibility = .private
    }
}

/// Who can reach a Linux instance's DS9 access points. Private registers them
/// in a per-instance 0700 directory that only `theiactl` reaches. Public
/// registers them the way DS9 does, so unmodified `xpaget ds9`, `xpaset ds9`
/// and pyds9 scripts find Theia; that also opens them to every local user.
public enum XPAVisibility: String, CaseIterable, Sendable {
    case `private`
    case `public`

    /// Environment variable that overrides the preference: `public` or `private`.
    public static let environmentKey = "THEIA_XPA"

    public static func resolve(environment: [String: String],
                               preference: XPAVisibility) -> XPAVisibility {
        environment[environmentKey].flatMap { XPAVisibility(rawValue: $0.lowercased()) } ?? preference
    }
}
