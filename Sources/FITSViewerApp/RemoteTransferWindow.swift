import AppKit

/// A cancellable status window shown while SSH is fetching a remote FITS file.
@MainActor final class RemoteTransferWindow: NSObject, NSWindowDelegate {
    let cancelButton: NSButton
    private let panel: NSPanel
    private let onCancel: @MainActor () -> Void
    private var finished = false

    init(filename: String, host: String, onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Opening remote FITS file"
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        super.init()
        panel.delegate = self
        let content = NSStackView()
        content.orientation = .vertical
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let label = NSTextField(labelWithString: "Fetching \(filename) from \(host)…")
        label.lineBreakMode = .byTruncatingMiddle
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, label])
        row.spacing = 12
        content.addArrangedSubview(row)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        let buttons = NSStackView(views: [cancelButton])
        buttons.alignment = .trailing
        content.addArrangedSubview(buttons)
        panel.contentView = content
        panel.center()
    }

    func present() { panel.makeKeyAndOrderFront(nil) }

    func dismiss() {
        guard !finished else { return }
        finished = true
        panel.close()
    }

    @objc private func cancel() {
        guard !finished else { return }
        finished = true
        panel.close()
        onCancel()
    }

    func windowWillClose(_ notification: Notification) { cancel() }
}
