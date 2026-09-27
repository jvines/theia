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
            OverlayCanvas.draw(OverlayScene.contours(leveled, mapping: mapping), in: context)
        }
        .allowsHitTesting(false)
    }

}

struct ContourLevelsPanel: View {
    @State private var model: ContourLevelsModel
    let onChange: (ContourSpec) -> Void

    init(model: ContourLevelsModel, onChange: @escaping (ContourSpec) -> Void) {
        self._model = State(initialValue: model)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show contours", isOn: $model.spec.enabled)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text("Count").frame(width: 50, alignment: .trailing)
                    Stepper(value: $model.spec.count, in: 1...32) {
                        Text("\(model.spec.count)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 30, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Min").frame(width: 50, alignment: .trailing)
                    TextField("", text: $model.minText, onCommit: { model.commitMin() })
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                GridRow {
                    Text("Max").frame(width: 50, alignment: .trailing)
                    TextField("", text: $model.maxText, onCommit: { model.commitMax() })
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                GridRow {
                    Text("Spacing").frame(width: 50, alignment: .trailing)
                    Picker("", selection: $model.spec.spacing) {
                        ForEach(ContourSpec.Spacing.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
            HStack {
                Button("Use data range") { model.useDataRange() }
                Spacer()
                if let range = model.dataRangeText {
                    Text(range)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.previewText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(minWidth: 360)
        .onChange(of: model.spec) { _, new in onChange(new) }
    }
}

@MainActor
final class ContourLevelsWindowController: NSWindowController {
    static private(set) var shared: ContourLevelsWindowController?

    static func show(model: ContourLevelsModel,
                     onChange: @escaping (ContourSpec) -> Void,
                     attachedTo parent: NSWindow?) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let view = ContourLevelsPanel(model: model, onChange: onChange)
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
