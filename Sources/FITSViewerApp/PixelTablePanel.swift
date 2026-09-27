import SwiftUI
import AppKit
import FITSCore
import FITSRender
import TheiaKit

/// Floating panel showing a (size × size) grid of pixel values centered on the cursor,
/// with the active pixel highlighted. Updates live as the cursor moves over the image.
struct PixelTablePanel: View {
    let imageProvider: () -> FITSImage?
    let cursor: CursorInfo?
    let imageRevision: Int
    @State private var gridSize = PixelTableModel(size: UserPreferences.shared.pixelTableSize).size

    var body: some View {
        let table = PixelTableModel(size: gridSize).snapshot(image: imageProvider(), cursor: cursor)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pixel Table").font(.headline)
                Spacer()
                Picker("Size", selection: $gridSize) {
                    ForEach(PixelTableModel.sizes, id: \.self) { size in
                        Text("\(size)×\(size)").tag(size)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
            }
            grid(table)
                .frame(maxWidth: .infinity)
            footer(table)
        }
        .padding(12)
        .frame(minWidth: CGFloat(gridSize * 60) + 24, minHeight: CGFloat(gridSize * 24) + 100)
        .onChange(of: gridSize) { _, size in UserPreferences.shared.pixelTableSize = size }
    }

    @ViewBuilder
    private func grid(_ table: PixelTableSnapshot?) -> some View {
        if let table {
            VStack(spacing: 1) {
                ForEach(table.rows.indices, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(table.rows[row].indices, id: \.self) { col in
                            cell(table.rows[row][col])
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
    private func footer(_ table: PixelTableSnapshot?) -> some View {
        if let table {
            HStack(spacing: 12) {
                Text(table.coordinateText)
                Text(table.valueText)
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private func cell(_ cell: PixelTableCell) -> some View {
        Text(cell.text)
            .font(.system(.caption2, design: .monospaced))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 20)
            .padding(.horizontal, 2)
            .background(cell.isActive ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.08))
            .foregroundStyle(cell.value.isNaN ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
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
    var imageRevision = 0 {
        didSet {
            if imageRevision != oldValue {
                NotificationCenter.default.post(name: Self.cursorChanged, object: self)
            }
        }
    }
}

private struct PixelTableContainerView: View {
    let provider: () -> FITSImage?
    let cursorBridge: PixelTableCursorBridge
    @State private var liveCursor: CursorInfo?
    @State private var liveRevision = 0

    var body: some View {
        PixelTablePanel(imageProvider: provider, cursor: liveCursor,
                        imageRevision: liveRevision)
            .onAppear {
                liveCursor = cursorBridge.cursor
                liveRevision = cursorBridge.imageRevision
            }
            .onReceive(NotificationCenter.default.publisher(for: PixelTableCursorBridge.cursorChanged)) { note in
                guard let bridge = note.object as? PixelTableCursorBridge, bridge === cursorBridge else { return }
                liveCursor = bridge.cursor
                liveRevision = bridge.imageRevision
            }
    }
}
