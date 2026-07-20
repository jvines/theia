import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shown on launch when no documents are open. Big icon, drop target, recent files,
/// a few helpful tips. Closes automatically when the first document opens.
@MainActor
final class WelcomeWindowController: NSWindowController {
    static private(set) var shared: WelcomeWindowController?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let view = WelcomeView { url in
            AppDelegate.shared?.openDocument(at: url)
            shared?.close()
        } openPanel: {
            AppDelegate.shared?.openDocumentAction(nil)
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        let c = WelcomeWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }

    static func closeIfOpen() {
        shared?.close()
    }
}

extension WelcomeWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct WelcomeView: View {
    let openURL: (URL) -> Void
    let openPanel: () -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            // Left: hero with icon + drop target
            VStack(spacing: 18) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .shadow(color: AppTheme.accent.opacity(0.5), radius: 28, y: 6)
                }
                VStack(spacing: 4) {
                    Text("Theia")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Photometry, spectra, regions —\nnative macOS, no Python required.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(isTargeted ? AppTheme.accent : .secondary.opacity(0.6))
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isTargeted ? AppTheme.accentSoft : .clear)
                        )
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.title2)
                        Text("Drop a .fits file here")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 80)
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { openURL(url) }
                    }
                    return true
                }
                HStack(spacing: 10) {
                    Button("Open…") { openPanel() }
                        .keyboardShortcut("o", modifiers: .command)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                    if let sample = sampleFITS {
                        Button {
                            openURL(sample)
                        } label: {
                            Label("Open Sample", systemImage: "sparkles")
                        }
                        .controlSize(.large)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: [
                    AppTheme.accentSoft.opacity(0.6),
                    Color(nsColor: .windowBackgroundColor),
                ], startPoint: .top, endPoint: .bottom)
            )

            Divider()

            // Right: recents + tips
            VStack(alignment: .leading, spacing: 14) {
                Text("Recent")
                    .font(.headline)
                if recentURLs.isEmpty {
                    Text("Files you open will show up here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(recentURLs, id: \.path) { url in
                                Button {
                                    openURL(url)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc")
                                            .foregroundStyle(AppTheme.accent)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(url.lastPathComponent).font(.body)
                                            Text(url.deletingLastPathComponent().path)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.001))
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                Divider()
                Text("Tips")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    tip(icon: "wand.and.stars", text: "Right-click + drag adjusts brightness/contrast (the classic astronomy convention).")
                    tip(icon: "ruler", text: "Mode → Measure to drag a line for angular separation.")
                    tip(icon: "scope", text: "Mode → Growth curve to pick aperture radii from where flux flattens.")
                    tip(icon: "circle.dotted.circle", text: "Drag the inner/outer rings of an annulus to retune in place.")
                    tip(icon: "terminal", text: "HTTP scripting on localhost:4321 — driveable from curl or Python.")
                }
                .font(.callout)
                Spacer()
            }
            .padding(20)
            .frame(width: 360)
        }
        .frame(width: 720, height: 460)
    }

    private func tip(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 18)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recentURLs: [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }

    /// First FITS we find in the project's `test_data/` folder (handy for dev launches),
    /// otherwise nil. In a notarized build this returns nil — the button just hides.
    private var sampleFITS: URL? {
        let candidates = [
            "test_data/simple_image/nicmos_mosaic.fits",
            "test_data/simple_image/foc_image.fits",
            "test_data/cubes/wfpc2_cube.fits",
        ]
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for c in candidates {
            let u = cwd.appendingPathComponent(c)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}
