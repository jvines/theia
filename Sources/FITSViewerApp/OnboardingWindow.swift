import SwiftUI
import AppKit
import TheiaKit

/// Shown once on first launch to introduce the app's capabilities.
/// After dismissal, the flag `hasSeenOnboarding` is set in UserDefaults
/// so it never appears automatically again. Re-openable from the Help menu.
@MainActor
final class OnboardingWindowController: NSWindowController {
    static private(set) var shared: OnboardingWindowController?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView {
            shared?.close()
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to Theia"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        let c = OnboardingWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct OnboardingView: View {
    let dismiss: () -> Void

    private let features: [(icon: String, title: String, detail: String)] = [
        (
            icon: "doc.richtext",
            title: "FITS & tile-compressed files",
            detail: "Opens standard FITS, multi-extension MEFs, image cubes, and tile-compressed .fz files transparently."
        ),
        (
            icon: "globe",
            title: "Full WCS support",
            detail: "World Coordinate System readout in ICRS, FK5, FK4, Galactic, or Ecliptic — switchable on the fly."
        ),
        (
            icon: "slider.horizontal.3",
            title: "Stretches & colormaps",
            detail: "Linear, log, asinh, square-root and more stretches; five built-in colour maps."
        ),
        (
            icon: "circle.dashed",
            title: "DS9-compatible regions",
            detail: "Draw and edit circles, ellipses, polygons, and text labels. Load and save standard .reg files."
        ),
        (
            icon: "scope",
            title: "Photometry & profiles",
            detail: "Aperture photometry with annular background subtraction, radial profiles, and growth curves."
        ),
        (
            icon: "terminal",
            title: "Scripting via XPA & HTTP",
            detail: "Drive the viewer from Python (pyds9), the shell (xpaget/xpaset), or curl via the local HTTP API."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .shadow(color: AppTheme.accent.opacity(0.45), radius: 20, y: 4)
                }
                Text("Theia")
                    .font(.system(size: 28, weight: .bold))
                Text("A fast, native FITS viewer for macOS")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 24)
            .background(
                LinearGradient(
                    colors: [AppTheme.accentSoft.opacity(0.8), Color(nsColor: .windowBackgroundColor)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Divider()

            // Feature grid
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 14
                ) {
                    ForEach(features, id: \.title) { feature in
                        FeatureRow(icon: feature.icon, title: feature.title, detail: feature.detail)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            Divider()

            // Footer
            HStack {
                Text("Version \(AppVersion.string)\(AppVersion.isBeta ? " · Beta" : "")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Get Started") {
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 480)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 30)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
