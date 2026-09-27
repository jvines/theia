import SwiftUI
import AppKit
import TheiaKit

/// Custom About panel — big icon, version, author credit, short description.
/// Less corporate than NSApp.orderFrontStandardAboutPanel.
@MainActor
final class AboutWindowController: NSWindowController {
    static private(set) var shared: AboutWindowController?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let view = AboutView()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.isFloatingPanel = false
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        let c = AboutWindowController(window: panel)
        shared = c
        panel.delegate = c
        panel.makeKeyAndOrderFront(nil)
    }
}

extension AboutWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { Self.shared = nil }

    /// Pops a small reference for the local HTTP scripting endpoints — handy for
    /// astronomers wiring this into Python / shell pipelines.
    static func showScriptingReference() {
        let port = ScriptingServer.shared.isRunning ? Int(ScriptingServer.shared.port) : 4321
        let tokenPath = ScriptingAuth.tokenURL().path
        let endpoints = ScriptingHTTPRouter.routeTable.map { route in
            let method = route.method.padding(toLength: 4, withPad: " ", startingAt: 0)
            let path = route.path.padding(toLength: 37, withPad: " ", startingAt: 0)
            return "  \(method) \(path) \(route.summary)"
        }.joined(separator: "\n")
        let text = """
        HTTP Scripting (localhost only)

          Base URL: http://127.0.0.1:\(port)

        Authentication
          Every request requires:
            Authorization: Bearer <token>
          Token file (0600, owner-only):
            \(tokenPath)

        Endpoints
        \(endpoints)

        Examples
          TOKEN=$(cat "\(tokenPath)")
          curl -s -H "Authorization: Bearer $TOKEN" localhost:\(port)/status | jq
          curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \\\\
               -d '{"path":"/abs/x.fits","stretch":"asinh","zscale":true}' \\\\
               localhost:\(port)/open
        """
        let alert = NSAlert()
        alert.messageText = "HTTP Scripting Reference"
        alert.informativeText = text
        alert.alertStyle = .informational
        let copyButton = alert.addButton(withTitle: "Copy reference")
        copyButton.tag = 1
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .shadow(color: AppTheme.accent.opacity(0.4), radius: 24, y: 4)
            }
            VStack(spacing: 2) {
                Text("Theia")
                    .font(.system(size: 24, weight: .semibold))
                Text(versionLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("A native macOS viewer for FITS data —\nphotometry, spectra, regions, the lot.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
            VStack(spacing: 2) {
                Text("Built by Jose Vines")
                    .font(.footnote)
                Text("Astronomer · Universidad Católica del Norte")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Link("Website", destination: URL(string: "https://jvines.cl")!)
                Text("·").foregroundStyle(.tertiary)
                Link("Source", destination: URL(string: "https://github.com/jvines")!)
            }
            .font(.footnote)
            Spacer(minLength: 0)
            Text("© 2026 José Vines · BSD-3-Clause")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 420, height: 380)
        .background(
            LinearGradient(colors: [
                Color(nsColor: .windowBackgroundColor),
                AppTheme.accentSoft.opacity(0.45),
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let b = info["CFBundleVersion"] as? String ?? "1"
        let betaSuffix = AppVersion.isBeta ? " · Beta" : ""
        return "version \(AppVersion.string) (\(b))\(betaSuffix)"
    }
}
