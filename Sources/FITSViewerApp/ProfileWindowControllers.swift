import AppKit
import SwiftUI
import FITSCore
import TheiaKit

@MainActor
final class LineProfileWindowController: NSWindowController {
    static private(set) var shared: LineProfileWindowController?

    static func show(model: LineProfileModel, imageName: String, attachedTo parent: NSWindow?) {
        let view = ProfilePlotView(
            title: "Line profile — \(imageName)",
            xLabel: "distance (px)",
            yLabel: "value",
            xValues: model.xValues,
            yValues: model.yValues,
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

    static func show(model: CubeSpectrumModel, attachedTo parent: NSWindow?) {
        let view = CubeSpectrumView(model: model)
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
    @State private var model: CubeSpectrumModel

    init(model: CubeSpectrumModel) {
        self._model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProfilePlotView(title: model.title, xLabel: model.xLabel, yLabel: "value",
                            xValues: model.xs, yValues: model.ys,
                            highlightX: model.plotHighlight)
            HStack(spacing: 6) {
                Text("Fit center").font(.caption).foregroundStyle(.secondary)
                TextField(model.xLabel, text: $model.fitCenterText).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("± width").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $model.fitHalfWidthText).textFieldStyle(.roundedBorder).frame(width: 70)
                Button("Fit Gaussian") {
                    model.runFit()
                }
                Button("Auto") {
                    model.autoFit()
                }
                if let fitText = model.fitText {
                    Text(fitText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
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
