import SwiftUI
import AppKit
import TheiaKit

@MainActor
final class LightCurveWindowController: NSWindowController {
    static private(set) var shared: LightCurveWindowController?

    static func show(model: LightCurveModel, attachedTo parent: NSWindow?) {
        let view = LightCurveView(model: model)
        if let existing = shared {
            existing.window?.contentView = NSHostingView(rootView: view)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Light Curve"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: view)
        if let parent {
            panel.setFrameOrigin(NSPoint(x: parent.frame.minX + 60, y: parent.frame.minY + 60))
        } else { panel.center() }
        let c = LightCurveWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }
}

extension LightCurveWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct LightCurveView: View {
    @State private var model: LightCurveModel

    init(model: LightCurveModel) {
        self._model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Light curve — \(model.points.count) frames")
                    .font(.headline)
                Spacer()
                Toggle("Normalize to median", isOn: $model.normalized)
                    .controlSize(.small)
                Button("Copy CSV") { copyCSV() }
                    .controlSize(.small)
            }
            GeometryReader { geo in
                Canvas { ctx, size in
                    draw(in: ctx, size: size)
                }
                .background(Color.black.opacity(0.9))
                .cornerRadius(4)
            }
            HStack {
                Text(model.timeLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.yLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let pad: CGFloat = 24
        let w = size.width - 2 * pad, h = size.height - 2 * pad
        let points = model.displayedPoints
        guard w > 0, h > 0, !points.isEmpty else { return }
        let xs = points.map(\.time)
        let ys = points.map(\.flux)
        let errs = points.map(\.err)
        let xMin = xs.min() ?? 0, xMax = xs.max() ?? 1
        let span = max(xMax - xMin, 1e-12)
        var yLo = (ys + zip(ys, errs).map(-)).min() ?? 0
        var yHi = (ys + zip(ys, errs).map(+)).max() ?? 1
        let pad2 = max((yHi - yLo) * 0.05, 1e-9)
        yLo -= pad2; yHi += pad2
        let yspan = max(yHi - yLo, 1e-12)
        func mapX(_ x: Double) -> CGFloat { pad + CGFloat((x - xMin) / span) * w }
        func mapY(_ y: Double) -> CGFloat { size.height - pad - CGFloat((y - yLo) / yspan) * h }

        // Axes.
        var axes = Path()
        axes.move(to: CGPoint(x: pad, y: pad))
        axes.addLine(to: CGPoint(x: pad, y: size.height - pad))
        axes.addLine(to: CGPoint(x: size.width - pad, y: size.height - pad))
        ctx.stroke(axes, with: .color(.white.opacity(0.35)), lineWidth: 1)

        // Error bars + points.
        let accent = Color(red: 0.55, green: 0.43, blue: 0.92)
        for i in 0..<points.count {
            let x = mapX(xs[i])
            let yC = mapY(ys[i])
            let yLoP = mapY(ys[i] - errs[i])
            let yHiP = mapY(ys[i] + errs[i])
            var bar = Path()
            bar.move(to: CGPoint(x: x, y: yLoP))
            bar.addLine(to: CGPoint(x: x, y: yHiP))
            ctx.stroke(bar, with: .color(.white.opacity(0.55)), lineWidth: 1)
            let r: CGFloat = 3
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: yC - r, width: r * 2, height: r * 2)),
                     with: .color(accent))
        }
    }

    private func copyCSV() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.csv, forType: .string)
    }
}
