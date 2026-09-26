import Foundation

public enum DrawMode: String, CaseIterable, Sendable {
    case pan
    case drawCircle
    case drawBox
    case drawEllipse
    case drawAnnulus
    case drawPolygon
    case lineProfile
    case radialProfile
    case growthCurve
    case measure
    case cubeSpectrum

    public var label: String {
        switch self {
        case .pan: return "Pan"
        case .drawCircle: return "Circle"
        case .drawBox: return "Box"
        case .drawEllipse: return "Ellipse"
        case .drawAnnulus: return "Annulus"
        case .drawPolygon: return "Polygon"
        case .lineProfile: return "Line profile"
        case .radialProfile: return "Radial profile"
        case .growthCurve: return "Growth curve"
        case .measure: return "Measure"
        case .cubeSpectrum: return "Cube spectrum"
        }
    }

    public var systemImage: String {
        switch self {
        case .pan: return "hand.draw"
        case .drawCircle: return "circle"
        case .drawBox: return "rectangle"
        case .drawEllipse: return "oval"
        case .drawAnnulus: return "circle.dotted.circle"
        case .drawPolygon: return "hexagon"
        case .lineProfile: return "scribble"
        case .radialProfile: return "scope"
        case .growthCurve: return "chart.line.uptrend.xyaxis"
        case .measure: return "ruler"
        case .cubeSpectrum: return "waveform"
        }
    }

    /// True for any mode where a primary mouse drag should produce a region instead
    /// of panning the image.
    public var isDrag: Bool {
        switch self {
        case .drawCircle, .drawBox, .drawEllipse, .drawAnnulus,
             .lineProfile, .measure, .radialProfile, .growthCurve: return true
        case .pan, .drawPolygon, .cubeSpectrum: return false
        }
    }
}
