import SwiftUI
import AppKit
import FITSCore
import FITSRender
import TheiaKit

/// Modeless inspector for adjusting brightness scale: numeric vmin/vmax fields,
/// percentile preset buttons, and a tiny histogram preview with draggable handles.
/// Classic Scale Parameters dialog.
struct ScaleParametersPanel: View {
    let viewport: ImageViewState
    let physicalValuesProvider: () -> [Double]
    let onApplyPreset: (ScalePreset) -> Void

    @State private var vminText: String = ""
    @State private var vmaxText: String = ""
    @State private var lowerPctText: String = "1"
    @State private var upperPctText: String = "99"
    @State private var dataMin: Double = .nan
    @State private var dataMax: Double = .nan
    @State private var cachedValues: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scale Parameters")
                .font(.headline)

            if !cachedValues.isEmpty {
                section(title: "Histogram") {
                    HistogramView(physicalValues: cachedValues, viewport: viewport)
                }
            }

            section(title: "Limits") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("vmin").frame(width: 50, alignment: .trailing)
                        TextField("", text: $vminText, onCommit: commitVmin)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Stepper("", value: vminBinding, step: stepSize)
                            .labelsHidden()
                    }
                    GridRow {
                        Text("vmax").frame(width: 50, alignment: .trailing)
                        TextField("", text: $vmaxText, onCommit: commitVmax)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Stepper("", value: vmaxBinding, step: stepSize)
                            .labelsHidden()
                    }
                }
                Text(dataRangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section(title: "Preset") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Percentile")
                            .frame(width: 70, alignment: .trailing)
                        TextField("lo", text: $lowerPctText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("–")
                        TextField("hi", text: $upperPctText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Button("Apply") { applyPercentile() }
                    }
                }
                HStack(spacing: 6) {
                    presetButton("ZScale", .zscale)
                    presetButton("Min / Max", .minMax)
                    presetButton("99 %",  .percentile(lower: 0.5, upper: 99.5))
                    presetButton("99.5 %", .percentile(lower: 0.25, upper: 99.75))
                    presetButton("99.9 %", .percentile(lower: 0.05, upper: 99.95))
                }
            }

            if viewport.stretch.usesParameter {
                section(title: "Power exponent") {
                    HStack(spacing: 8) {
                        Slider(value: powerExponentBinding, in: 0.1...8.0)
                            .frame(width: 200)
                        Text(String(format: "%.2f", viewport.stretchParameter))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50, alignment: .trailing)
                    }
                    Text("Pixel mapping: n = x^p · (p=1 → linear, p<1 → brighten lows, p>1 → darken lows)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 380)
        .onAppear { refreshFromViewport(); refreshDataRange() }
        .onChange(of: viewport.vmin) { _, _ in refreshFromViewport() }
        .onChange(of: viewport.vmax) { _, _ in refreshFromViewport() }
    }

    // MARK: - Helpers

    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            content()
        }
    }

    private func presetButton(_ title: String, _ preset: ScalePreset) -> some View {
        Button(title) { onApplyPreset(preset) }
            .buttonStyle(.bordered)
    }

    private var dataRangeLabel: String {
        guard dataMin.isFinite, dataMax.isFinite else { return "Data range: —" }
        return String(format: "Data range: %.6g … %.6g", dataMin, dataMax)
    }

    private var stepSize: Double {
        guard dataMin.isFinite, dataMax.isFinite else { return 1 }
        let span = max(abs(dataMax - dataMin), 1e-9)
        return span / 200.0
    }

    private var vminBinding: Binding<Double> {
        Binding(
            get: { Double(viewport.vmin) },
            set: { viewport.vmin = Float($0) }
        )
    }

    private var vmaxBinding: Binding<Double> {
        Binding(
            get: { Double(viewport.vmax) },
            set: { viewport.vmax = Float($0) }
        )
    }

    private var powerExponentBinding: Binding<Double> {
        Binding(
            get: { Double(viewport.stretchParameter) },
            set: { viewport.stretchParameter = Float($0) }
        )
    }

    private func refreshFromViewport() {
        vminText = formatLevel(Double(viewport.vmin))
        vmaxText = formatLevel(Double(viewport.vmax))
    }

    private func refreshDataRange() {
        let values = physicalValuesProvider()
        cachedValues = values
        if let r = PixelStatistics.minMax(values) {
            dataMin = r.min
            dataMax = r.max
        } else {
            dataMin = .nan
            dataMax = .nan
        }
    }

    private func commitVmin() {
        if let v = Double(vminText) { viewport.vmin = Float(v) }
        refreshFromViewport()
    }

    private func commitVmax() {
        if let v = Double(vmaxText) { viewport.vmax = Float(v) }
        refreshFromViewport()
    }

    private func applyPercentile() {
        guard let lo = Double(lowerPctText), let hi = Double(upperPctText) else { return }
        onApplyPreset(.percentile(lower: lo, upper: hi))
    }

    private func formatLevel(_ v: Double) -> String {
        if !v.isFinite { return "—" }
        let abs = Swift.abs(v)
        if abs == 0 { return "0" }
        if abs >= 1000 || abs < 0.01 { return String(format: "%.4g", v) }
        return String(format: "%.4f", v)
    }
}

/// Floating panel host so the user can keep tweaking the scale while watching the image.
@MainActor
final class ScaleParametersWindowController: NSWindowController {
    static func show(viewport: ImageViewState,
                     physicalValuesProvider: @escaping () -> [Double],
                     onApplyPreset: @escaping (ScalePreset) -> Void,
                     attachedTo parent: NSWindow?) {
        let view = ScaleParametersPanel(
            viewport: viewport,
            physicalValuesProvider: physicalValuesProvider,
            onApplyPreset: onApplyPreset
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scale Parameters"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: view)
        if let parent {
            panel.setFrameOrigin(NSPoint(
                x: parent.frame.maxX - 400,
                y: parent.frame.maxY - 300
            ))
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }
}
