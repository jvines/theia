import AppKit
import TheiaKit

@MainActor enum ViewMenuFocus {
    static func documentWindow(
        key: NSWindow?, main: NSWindow?, documents: [NSWindow]
    ) -> NSWindow? {
        guard let key else { return nil }
        if let document = documents.first(where: { $0 === key }) { return document }
        var parent = key.parent
        while let window = parent {
            if let document = documents.first(where: { $0 === window }) { return document }
            parent = window.parent
        }
        if key is NSPanel, let main,
           let document = documents.first(where: { $0 === main }) {
            return document
        }
        return nil
    }
}

/// Adds shared view commands to the Mac menu bar. AppKit validates each item
/// when the menu opens so commands always target the current document window.
@MainActor
final class ViewCommandsMenuController: NSObject, NSMenuItemValidation {
    private var installed = false

    func install() {
        guard !installed, let mainMenu = NSApp.mainMenu else { return }
        let viewMenu: NSMenu
        if let existing = mainMenu.item(withTitle: "View") {
            if let submenu = existing.submenu {
                viewMenu = submenu
            } else {
                viewMenu = NSMenu(title: "View")
                existing.submenu = viewMenu
            }
            if !viewMenu.items.isEmpty { viewMenu.addItem(.separator()) }
        } else {
            let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            viewMenu = NSMenu(title: "View")
            item.submenu = viewMenu
            let index = mainMenu.items.firstIndex { $0.title == "Window" || $0.title == "Help" }
                ?? mainMenu.items.count
            mainMenu.insertItem(item, at: index)
        }

        for entry in CommandCatalog.viewMenu(for: nil) {
            guard let descriptor = entry.item, let command = descriptor.command else { continue }
            let item = NSMenuItem(title: descriptor.title,
                                  action: #selector(performViewCommand(_:)),
                                  keyEquivalent: descriptor.shortcut?.key ?? "")
            item.identifier = NSUserInterfaceItemIdentifier(descriptor.identifier)
            item.keyEquivalentModifierMask = descriptor.shortcut?.shift == true
                ? [.command, .shift] : [.command]
            item.target = self
            item.representedObject = ViewCommandBox(command)
            viewMenu.addItem(item)
        }
        installImageMenu(in: mainMenu)
        installed = true
    }

    private func installImageMenu(in mainMenu: NSMenu) {
        let imageMenu: NSMenu
        if let existing = mainMenu.item(withTitle: "Image") {
            imageMenu = existing.submenu ?? NSMenu(title: "Image")
            existing.submenu = imageMenu
            if !imageMenu.items.isEmpty { imageMenu.addItem(.separator()) }
        } else {
            let item = NSMenuItem(title: "Image", action: nil, keyEquivalent: "")
            imageMenu = NSMenu(title: "Image")
            item.submenu = imageMenu
            let index = mainMenu.items.firstIndex { $0.title == "Window" || $0.title == "Help" }
                ?? mainMenu.items.count
            mainMenu.insertItem(item, at: index)
        }
        for entry in CommandCatalog.imageMenu(for: nil) {
            guard let descriptor = entry.item else {
                imageMenu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: descriptor.title,
                                  action: #selector(performImageCommand(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(descriptor.identifier)
            item.target = self
            imageMenu.addItem(item)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let identifier = menuItem.identifier?.rawValue else { return false }
        if identifier.hasPrefix("image.") {
            guard let descriptor = CommandCatalog.imageMenu(
                for: AppDelegate.shared?.activeSessionForMenu()
            ).compactMap(\.item).first(where: { $0.identifier == identifier }) else { return false }
            if case .checked(let checked) = descriptor.state {
                menuItem.state = checked ? .on : .off
            }
            return descriptor.enabled
        }
        return CommandCatalog.viewMenu(for: AppDelegate.shared?.activeSessionForMenu())
            .compactMap(\.item)
            .first { $0.identifier == identifier }?.enabled ?? false
    }

    @objc private func performViewCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ViewCommandBox,
              let session = AppDelegate.shared?.activeSessionForMenu() else { return }
        _ = session.perform(box.command, origin: .user)
    }

    @objc private func performImageCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue,
              let session = AppDelegate.shared?.activeSessionForMenu(),
              let descriptor = CommandCatalog.imageMenu(for: session)
                .compactMap(\.item).first(where: { $0.identifier == identifier }),
              descriptor.enabled, let command = descriptor.command else { return }
        let outcome = session.perform(command, origin: .user)
        if outcome.failure == nil {
            for effect in outcome.effects { AppDelegate.shared?.applyEffect(effect) }
        }
    }
}

private final class ViewCommandBox: NSObject {
    let command: SessionCommand
    init(_ command: SessionCommand) { self.command = command }
}
