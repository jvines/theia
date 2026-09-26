import SwiftUI
import AppKit
import FITSCore
import FITSRender

/// Floating panel showing a (size × size) grid of pixel values centered on the cursor,
/// with the active pixel highlighted. Updates live as the cursor moves over the image.
struct PixelTablePanel: View {
    let imageProvider: () -> FITSImage?
    let cursor: CursorInfo?
    @State private var gridSize: Int = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pixel Table").font(.headline)
                Spacer()
                Picker("Size", selection: $gridSize) {
                    Text("5×5").tag(5)
                    Text("7×7").tag(7)
                    Text("9×9").tag(9)
                    Text("11×11").tag(11)
                }
                .pickerStyle(.menu)
                .frame(width: 90)
            }
            grid
                .frame(maxWidth: .infinity)
            footer
        }
        .padding(12)
        .frame(minWidth: CGFloat(gridSize * 60) + 24, minHeight: CGFloat(gridSize * 24) + 100)
    }

    @ViewBuilder
    private var grid: some View {
        if let image = imageProvider(), let c = cursor {
            let half = gridSize / 2
            VStack(spacing: 1) {
                ForEach(0..<gridSize, id: \.self) { row in
                    // Top of grid = high Y. row 0 = c.imageY + half.
                    let y = c.imageY + (half - row)
                    HStack(spacing: 1) {
                        ForEach(0..<gridSize, id: \.self) { col in
                            let x = c.imageX - half + col
                            cell(x: x, y: y, image: image, highlight: row == half && col == half)
                        }
                    }
                }
            }
        } else {
            Text("Move the cursor over the image to populate.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let c = cursor {
            HStack(spacing: 12) {
                Text("(x, y) = (\(c.fitsX), \(c.fitsY))")
                Text("value = \(c.value.isNaN ? "NaN" : String(format: "%.6g", c.value))")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private func cell(x: Int, y: Int, image: FITSImage, highlight: Bool) -> some View {
        let value: Double
        if x < 0 || x >= image.width || y < 0 || y >= image.height {
            value = .nan
        } else {
            value = image.physicalValue(x: x, y: y)
        }
        let text = value.isNaN ? "—" : String(format: "%.3g", value)
        return Text(text)
            .font(.system(.caption2, design: .monospaced))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 20)
            .padding(.horizontal, 2)
            .background(highlight ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.08))
            .foregroundStyle(value.isNaN ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
    }
}

@MainActor
final class PixelTableWindowController: NSWindowController {
    /// Shared single instance so reopening doesn't spawn duplicates.
    static private(set) var shared: PixelTableWindowController?

    static func show(provider: @escaping () -> FITSImage?,
                     cursorPublisher: PixelTableCursorBridge,
                     attachedTo parent: NSWindow?) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pixel Table"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let view = PixelTableContainerView(provider: provider, cursorBridge: cursorPublisher)
        panel.contentView = NSHostingView(rootView: view)
        if let parent {
            panel.setFrameOrigin(NSPoint(x: parent.frame.minX + 24, y: parent.frame.minY + 24))
        } else {
            panel.center()
        }
        let controller = PixelTableWindowController(window: panel)
        shared = controller
        panel.delegate = controller
        panel.makeKeyAndOrderFront(nil)
    }
}

extension PixelTableWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

/// Lets the panel observe cursor updates from `DocumentView` without coupling.
/// Plain class — not ObservableObject — to keep DocumentView's body type-checkable.
/// Cursor changes post a Notification that the panel's view subscribes to.
final class PixelTableCursorBridge {
    static let cursorChanged = Notification.Name("PixelTableCursorChanged")
    var cursor: CursorInfo? {
        didSet { NotificationCenter.default.post(name: Self.cursorChanged, object: self) }
    }
}

private struct PixelTableContainerView: View {
    let provider: () -> FITSImage?
    let cursorBridge: PixelTableCursorBridge
    @State private var liveCursor: CursorInfo?

    var body: some View {
        PixelTablePanel(imageProvider: provider, cursor: liveCursor)
            .onAppear { liveCursor = cursorBridge.cursor }
            .onReceive(NotificationCenter.default.publisher(for: PixelTableCursorBridge.cursorChanged)) { note in
                guard let bridge = note.object as? PixelTableCursorBridge, bridge === cursorBridge else { return }
                liveCursor = bridge.cursor
            }
    }
}
