import SwiftUI
import simd
import FITSCore
import FITSRender
import TheiaKit

/// SwiftUI overlay drawing contour segments computed from `FITSImage` data.
/// Segments are extracted on demand for the current spec; the calling view should
/// pre-compute and cache to avoid recomputing on every viewport change.
struct ContourOverlay: View {
    let leveled: [Contours.LeveledSegments]
    let imageHeight: Int
    let viewport: ImageViewState

    var body: some View {
        let transform = viewport.transform
        Canvas { context, size in
            let mapping = ViewMapping(
                transform: transform,
                viewSize: SIMD2(Double(size.width), Double(size.height)),
                backingScale: 1
            )
            // Match WCS grid colour family: faint cyan, denser per level.
            for (idx, lvl) in leveled.enumerated() {
                let alpha = 0.45 + 0.55 * Double(idx + 1) / Double(max(leveled.count, 1))
                let colour = Color.cyan.opacity(alpha)
                var path = Path()
                for s in lvl.segments {
                    let a = canvasPoint(s.a, mapping: mapping)
                    let b = canvasPoint(s.b, mapping: mapping)
                    path.move(to: a)
                    path.addLine(to: b)
                }
                context.stroke(path, with: .color(colour), lineWidth: 1.0)
            }
        }
        .allowsHitTesting(false)
    }

    private func canvasPoint(_ image: SIMD2<Double>, mapping: ViewMapping) -> CGPoint {
        let point = mapping.imageToView(image)
        return CGPoint(x: point.x, y: point.y)
    }
}

struct ContourLevelsPanel: View {
    @State private var spec: ContourSpec
    @State private var minText: String
    @State private var maxText: String
    let dataMin: Double
    let dataMax: Double
    let onChange: (ContourSpec) -> Void

    init(initial: ContourSpec, dataMin: Double, dataMax: Double, onChange: @escaping (ContourSpec) -> Void) {
        var s = initial
        if !s.minValue.isFinite, dataMin.isFinite { s.minValue = dataMin }
        if !s.maxValue.isFinite, dataMax.isFinite { s.maxValue = dataMax }
        self._spec = State(initialValue: s)
        self._minText = State(initialValue: Self.format(s.minValue))
        self._maxText = State(initialValue: Self.format(s.maxValue))
        self.dataMin = dataMin
        self.dataMax = dataMax
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show contours", isOn: $spec.enabled)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text("Count").frame(width: 50, alignment: .trailing)
                    Stepper(value: $spec.count, in: 1...32) {
                        Text("\(spec.count)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 30, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Min").frame(width: 50, alignment: .trailing)
                    TextField("", text: $minText, onCommit: commitMin)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                GridRow {
                    Text("Max").frame(width: 50, alignment: .trailing)
                    TextField("", text: $maxText, onCommit: commitMax)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                GridRow {
                    Text("Spacing").frame(width: 50, alignment: .trailing)
                    Picker("", selection: $spec.spacing) {
                        ForEach(ContourSpec.Spacing.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
            HStack {
                Button("Use data range") {
                    if dataMin.isFinite {
                        spec.minValue = dataMin
                        minText = Self.format(dataMin)
                    }
                    if dataMax.isFinite {
                        spec.maxValue = dataMax
                        maxText = Self.format(dataMax)
                    }
                }
                Spacer()
                if dataMin.isFinite, dataMax.isFinite {
                    Text(String(format: "data %.3g … %.3g", dataMin, dataMax))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(previewLevels)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(minWidth: 360)
        .onChange(of: spec) { _, new in onChange(new) }
    }

    private func commitMin() {
        if let v = Double(minText.replacingOccurrences(of: ",", with: ".")) {
            spec.minValue = v
            minText = Self.format(v)
        } else {
            minText = Self.format(spec.minValue)
        }
    }

    private func commitMax() {
        if let v = Double(maxText.replacingOccurrences(of: ",", with: ".")) {
            spec.maxValue = v
            maxText = Self.format(v)
        } else {
            maxText = Self.format(spec.maxValue)
        }
    }

    private var previewLevels: String {
        let lvls = spec.levels()
        guard !lvls.isEmpty else { return "—" }
        return "levels: " + lvls.map { String(format: "%.4g", $0) }.joined(separator: ", ")
    }

    private static func format(_ v: Double) -> String {
        if !v.isFinite { return "" }
        if abs(v) >= 1e4 || (v != 0 && abs(v) < 0.01) { return String(format: "%.4g", v) }
        return String(format: "%.4f", v)
    }
}

@MainActor
final class ContourLevelsWindowController: NSWindowController {
    static private(set) var shared: ContourLevelsWindowController?

    static func show(initial: ContourSpec,
                     dataMin: Double, dataMax: Double,
                     onChange: @escaping (ContourSpec) -> Void,
                     attachedTo parent: NSWindow?) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let view = ContourLevelsPanel(initial: initial, dataMin: dataMin, dataMax: dataMax, onChange: onChange)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Contour Levels"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: view)
        if let parent {
            panel.setFrameOrigin(NSPoint(x: parent.frame.maxX - 400, y: parent.frame.maxY - 320))
        } else { panel.center() }
        let controller = ContourLevelsWindowController(window: panel)
        shared = controller
        panel.delegate = controller
        panel.makeKeyAndOrderFront(nil)
    }
}

extension ContourLevelsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}
