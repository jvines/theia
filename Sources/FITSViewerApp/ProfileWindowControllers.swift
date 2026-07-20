import AppKit
import SwiftUI
import FITSCore

@MainActor
final class LineProfileWindowController: NSWindowController {
    static private(set) var shared: LineProfileWindowController?

    static func show(samples: [Profiles.LineSample], imageName: String, attachedTo parent: NSWindow?) {
        let view = ProfilePlotView(
            title: "Line profile — \(imageName)",
            xLabel: "distance (px)",
            yLabel: "value",
            xValues: samples.map(\.distance),
            yValues: samples.map(\.value),
            highlightX: nil
        )
        .padding(12)
        if let existing = shared {
            existing.window?.contentView = NSHostingView(rootView: AnyView(view))
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = makePanel(title: "Line Profile", parent: parent, content: view)
        let c = LineProfileWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }
}

extension LineProfileWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

@MainActor
final class RadialProfileWindowController: NSWindowController {
    static private(set) var shared: RadialProfileWindowController?

    static func show(image: FITSImage, center: SIMD2<Double>, initialRadius: Double,
                     imageName: String, attachedTo parent: NSWindow?,
                     onRadiusChange: @escaping (Double) -> Void) {
        let view = RadialProfileView(image: image, center: center,
                                     initialRadius: initialRadius, imageName: imageName,
                                     onRadiusChange: onRadiusChange)
        if let existing = shared {
            existing.window?.contentView = NSHostingView(rootView: view)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = makePanel(title: "Radial Profile", parent: parent, content: view)
        let c = RadialProfileWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }
}

extension RadialProfileWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct RadialProfileView: View {
    let image: FITSImage
    let center: SIMD2<Double>
    let initialRadius: Double
    let imageName: String
    let onRadiusChange: (Double) -> Void

    @State private var radius: Double
    @State private var binWidth: Double = 1

    init(image: FITSImage, center: SIMD2<Double>, initialRadius: Double,
         imageName: String, onRadiusChange: @escaping (Double) -> Void) {
        self.image = image; self.center = center; self.initialRadius = initialRadius
        self.imageName = imageName; self.onRadiusChange = onRadiusChange
        self._radius = State(initialValue: initialRadius)
    }

    var body: some View {
        let bins = Profiles.radialProfile(image: image, center: (center.x, center.y),
                                          maxRadius: radius, binWidth: binWidth)
        VStack(alignment: .leading, spacing: 6) {
            ProfilePlotView(
                title: "Radial profile — \(imageName)",
                xLabel: "radius (px)",
                yLabel: "mean value",
                xValues: bins.map(\.radius),
                yValues: bins.map(\.mean),
                highlightX: nil
            )
            controls
        }
        .padding(12)
    }

    private var maxAllowed: Double {
        let maxImageR = min(Double(image.width), Double(image.height))
        return max(maxImageR, initialRadius * 2)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text("max r").foregroundStyle(.secondary)
            Slider(value: $radius, in: 1...maxAllowed)
                .frame(width: 200)
                .onChange(of: radius) { _, new in onRadiusChange(new) }
            TextField("", value: $radius, format: .number.precision(.fractionLength(1)))
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
            Text("bin").foregroundStyle(.secondary)
            Stepper(value: $binWidth, in: 0.5...10, step: 0.5) {
                Text(String(format: "%.1f", binWidth)).frame(width: 32)
            }
            Spacer()
        }
        .font(.caption)
        .controlSize(.small)
    }
}

@MainActor
final class GrowthCurveWindowController: NSWindowController {
    static private(set) var shared: GrowthCurveWindowController?

    static func show(image: FITSImage, center: SIMD2<Double>, initialRadius: Double,
                     imageName: String, attachedTo parent: NSWindow?,
                     onRadiusChange: @escaping (Double) -> Void) {
        let view = GrowthCurveView(image: image, center: center,
                                   initialRadius: initialRadius, imageName: imageName,
                                   onRadiusChange: onRadiusChange)
        if let existing = shared {
            existing.window?.contentView = NSHostingView(rootView: view)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = makePanel(title: "Growth Curve", parent: parent, content: view)
        let c = GrowthCurveWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }
}

extension GrowthCurveWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct GrowthCurveView: View {
    let image: FITSImage
    let center: SIMD2<Double>
    let initialRadius: Double
    let imageName: String
    let onRadiusChange: (Double) -> Void

    @State private var radius: Double
    @State private var step: Double = 1

    init(image: FITSImage, center: SIMD2<Double>, initialRadius: Double,
         imageName: String, onRadiusChange: @escaping (Double) -> Void) {
        self.image = image; self.center = center; self.initialRadius = initialRadius
        self.imageName = imageName; self.onRadiusChange = onRadiusChange
        self._radius = State(initialValue: initialRadius)
    }

    var body: some View {
        let curve = Profiles.growthCurve(image: image, center: (center.x, center.y),
                                         maxRadius: radius, step: step)
        VStack(alignment: .leading, spacing: 6) {
            ProfilePlotView(
                title: "Growth curve — \(imageName)",
                xLabel: "aperture radius (px)",
                yLabel: "cumulative flux",
                xValues: curve.map(\.radius),
                yValues: curve.map(\.cumulativeFlux),
                highlightX: nil
            )
            HStack(spacing: 8) {
                Text("max r").foregroundStyle(.secondary)
                Slider(value: $radius, in: 1...maxAllowed)
                    .frame(width: 200)
                    .onChange(of: radius) { _, new in onRadiusChange(new) }
                TextField("", value: $radius, format: .number.precision(.fractionLength(1)))
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                Text("step").foregroundStyle(.secondary)
                Stepper(value: $step, in: 0.5...10, step: 0.5) {
                    Text(String(format: "%.1f", step)).frame(width: 32)
                }
                Spacer()
            }
            .font(.caption)
            .controlSize(.small)
        }
        .padding(12)
    }

    private var maxAllowed: Double {
        let maxImageR = min(Double(image.width), Double(image.height))
        return max(maxImageR, initialRadius * 2)
    }
}

@MainActor
final class CubeSpectrumWindowController: NSWindowController {
    static private(set) var shared: CubeSpectrumWindowController?

    static func show(values: [Double], currentPlane: Int, label: String, attachedTo parent: NSWindow?,
                     xValues: [Double]? = nil, xLabel: String = "plane") {
        let xs = xValues ?? (0..<values.count).map(Double.init)
        let highlight: Double? = (xValues == nil) ? Double(currentPlane) :
            (currentPlane < xs.count ? xs[currentPlane] : nil)
        let view = CubeSpectrumView(
            title: "Cube spectrum — \(label)",
            xLabel: xLabel,
            xs: xs, ys: values, highlightX: highlight
        )
        if let existing = shared {
            existing.window?.contentView = NSHostingView(rootView: AnyView(view))
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = makePanel(title: "Cube Spectrum", parent: parent, content: view)
        let c = CubeSpectrumWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct CubeSpectrumView: View {
    let title: String
    let xLabel: String
    let xs: [Double]
    let ys: [Double]
    let highlightX: Double?
    @State private var fit: Gaussian1D.Result?
    @State private var fitCenter: String = ""
    @State private var fitHalfWidth: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProfilePlotView(title: title, xLabel: xLabel, yLabel: "value",
                            xValues: xs, yValues: ys, highlightX: fit?.center ?? highlightX)
            HStack(spacing: 6) {
                Text("Fit center").font(.caption).foregroundStyle(.secondary)
                TextField(xLabel, text: $fitCenter).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("± width").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $fitHalfWidth).textFieldStyle(.roundedBorder).frame(width: 70)
                Button("Fit Gaussian") {
                    runFit()
                }
                Button("Auto") {
                    autoFit()
                }
                if let f = fit {
                    Text(String(format: "c=%.4g  σ=%.4g  FWHM=%.4g  amp=%.4g  bg=%.4g",
                                f.center, f.sigma, f.fwhm, f.amplitude, f.baseline))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func runFit() {
        guard let c = Double(fitCenter), let w = Double(fitHalfWidth), w > 0 else { return }
        fit = Gaussian1D.fit(xs: xs, ys: ys, near: c, halfWidth: w)
    }

    private func autoFit() {
        // Default centre = highlight or the brightest channel; width = 10% of range.
        let span = (xs.last ?? 0) - (xs.first ?? 0)
        let w = max(span * 0.1, 1)
        // Find argmax over y (NaN-skip).
        var bestX = xs.first ?? 0
        var bestY = -Double.infinity
        for i in xs.indices where !ys[i].isNaN {
            if ys[i] > bestY { bestY = ys[i]; bestX = xs[i] }
        }
        let c = highlightX ?? bestX
        fitCenter = String(format: "%.4g", c)
        fitHalfWidth = String(format: "%.4g", w)
        fit = Gaussian1D.fit(xs: xs, ys: ys, near: c, halfWidth: w)
    }
}

extension CubeSpectrumWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

@MainActor
private func makePanel<V: View>(title: String, parent: NSWindow?, content: V) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.title = title
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.contentView = NSHostingView(rootView: AnyView(content))
    if let parent {
        panel.setFrameOrigin(NSPoint(x: parent.frame.minX + 40, y: parent.frame.minY + 40))
    } else { panel.center() }
    return panel
}
