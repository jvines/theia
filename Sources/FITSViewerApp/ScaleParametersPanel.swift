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

    @State private var model = ScaleParametersModel(values: [], vmin: 0, vmax: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scale Parameters")
                .font(.headline)

            if model.valueCount > 0 {
                section(title: "Histogram") {
                    HistogramView(model: model, viewport: viewport)
                }
            }

            section(title: "Limits") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("vmin").frame(width: 50, alignment: .trailing)
                        TextField("", text: $model.vminText, onCommit: commitVmin)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Stepper("", value: vminBinding, step: model.stepSize)
                            .labelsHidden()
                    }
                    GridRow {
                        Text("vmax").frame(width: 50, alignment: .trailing)
                        TextField("", text: $model.vmaxText, onCommit: commitVmax)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Stepper("", value: vmaxBinding, step: model.stepSize)
                            .labelsHidden()
                    }
                }
                Text(model.dataRangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section(title: "Preset") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Percentile")
                            .frame(width: 70, alignment: .trailing)
                        TextField("lo", text: $model.lowerPctText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("–")
                        TextField("hi", text: $model.upperPctText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Button("Apply") { applyPercentile() }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(ScaleParametersModel.presets, id: \.self) { preset in
                        presetButton(preset)
                    }
                }
            }

            if viewport.stretch.usesParameter {
                section(title: "Power exponent") {
                    HStack(spacing: 8) {
                        Slider(value: powerExponentBinding, in: ScaleParametersModel.powerExponentRange)
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
        .onAppear { refreshDataRange() }
        .onChange(of: viewport.vmin) { _, _ in refreshFromViewport() }
        .onChange(of: viewport.vmax) { _, _ in refreshFromViewport() }
        .onChange(of: viewport.imageRevision) { _, _ in refreshDataRange() }
    }

    // MARK: - Helpers

    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            content()
        }
    }

    private func presetButton(_ preset: ScalePreset) -> some View {
        Button(preset.label) { onApplyPreset(preset) }
            .buttonStyle(.bordered)
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
            set: { viewport.stretchParameter = Float(model.clampedPowerExponent($0)) }
        )
    }

    private func refreshFromViewport() {
        model.refreshLevels(vmin: Double(viewport.vmin), vmax: Double(viewport.vmax))
    }

    private func refreshDataRange() {
        model = ScaleParametersModel(
            values: physicalValuesProvider(),
            vmin: Double(viewport.vmin), vmax: Double(viewport.vmax),
            lowerPctText: model.lowerPctText, upperPctText: model.upperPctText
        )
    }

    private func commitVmin() {
        if let value = model.parsedVmin { viewport.vmin = Float(value) }
        refreshFromViewport()
    }

    private func commitVmax() {
        if let value = model.parsedVmax { viewport.vmax = Float(value) }
        refreshFromViewport()
    }

    private func applyPercentile() {
        if let preset = model.percentilePreset { onApplyPreset(preset) }
    }
}

/// Floating panel host so the user can keep tweaking the scale while watching the image.
@MainActor
final class ScaleParametersWindowController: NSWindowController {
    private static var panels: [ObjectIdentifier: ScaleParametersWindowController] = [:]
    private var viewportID: ObjectIdentifier?

    static func close(for viewport: ImageViewState) {
        panels[ObjectIdentifier(viewport)]?.window?.close()
    }

    @discardableResult
    static func show(viewport: ImageViewState,
                     physicalValuesProvider: @escaping () -> [Double],
                     onApplyPreset: @escaping (ScalePreset) -> Void,
                     attachedTo parent: NSWindow?) -> ScaleParametersWindowController {
        let id = ObjectIdentifier(viewport)
        if let existing = panels[id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
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
        let controller = ScaleParametersWindowController(window: panel)
        controller.viewportID = id
        panels[id] = controller
        panel.delegate = controller
        panel.makeKeyAndOrderFront(nil)
        return controller
    }
}

extension ScaleParametersWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let viewportID { Self.panels[viewportID] = nil }
    }
}
