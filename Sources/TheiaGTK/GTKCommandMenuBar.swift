import CGtk4
import Foundation
import TheiaKit

/// Native GTK menus backed by the same command descriptors as the Mac menus.
@MainActor final class GTKCommandMenuBar {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let model: OpaquePointer
    private let window: UnsafeMutablePointer<GtkWindow>
    private let session: DocumentSession
    private var observerID: UUID?
    private var commands: [String: SessionCommand] = [:]
    private var toolActions: [String: ToolMenuAction] = [:]
    private var actions: [String: OpaquePointer] = [:]
    private var actionIDs: [String: String] = [:]
    private var titles: [String: String] = [:]
    var onOutcome: (@MainActor (CommandOutcome) -> Void)?
    var onToolAction: (@MainActor (ToolMenuAction) -> Void)?

    var sectionCount: Int {
        Int(g_menu_model_get_n_items(UnsafeMutablePointer<GMenuModel>(model)))
    }
    func title(for identifier: String) -> String? { titles[identifier] }
    func isEnabled(_ identifier: String) -> Bool {
        guard let action = actions[identifier] else { return false }
        return g_action_get_enabled(action) != 0
    }

    init(window: UnsafeMutablePointer<GtkWindow>, session: DocumentSession) {
        self.window = window
        self.session = session
        model = g_menu_new()!
        widget = gtk_popover_menu_bar_new_from_model(UnsafeMutablePointer<GMenuModel>(model))!
        rebuild()
        observerID = session.addEventObserver { [weak self] event in
            switch event.kind {
            case .displayParametersChanged, .imageRevisionChanged, .selectionChanged,
                 .regionsChanged, .overlaysChanged, .panelStateChanged, .playbackChanged,
                 .jobStatusChanged:
                self?.rebuild()
            default: break
            }
        }
    }

    deinit { g_object_unref(UnsafeMutableRawPointer(model)) }

    func stop() {
        if let observerID {
            session.removeEventObserver(observerID)
            self.observerID = nil
        }
    }

    func activate(_ identifier: String) {
        guard let action = actions[identifier] else { return }
        g_action_activate(action, nil)
    }

    private func rebuild() {
        g_menu_remove_all(model)
        titles.removeAll()
        commands.removeAll()
        toolActions.removeAll()
        let groups: [(String, [CommandMenuEntry])] = [
            ("View", CommandCatalog.viewMenu(for: session)),
            ("Image", CommandCatalog.imageMenu(for: session)),
            ("Regions", CommandCatalog.regionMenu(for: session)),
            ("Analysis", CommandCatalog.analysisMenu(for: session)),
            ("Stretch", CommandCatalog.sessionMenu("stretch", for: session) ?? []),
            ("Map", CommandCatalog.sessionMenu("map", for: session) ?? []),
            ("Mode", CommandCatalog.sessionMenu("mode", for: session) ?? []),
            ("Scale", CommandCatalog.sessionMenu("scale", for: session) ?? []),
            ("WCS", CommandCatalog.sessionMenu("wcsVariant", for: session) ?? []),
        ]
        for (title, entries) in groups {
            let submenu = g_menu_new()!
            var section = g_menu_new()!
            func finishSection() {
                if g_menu_model_get_n_items(UnsafeMutablePointer<GMenuModel>(section)) > 0 {
                    g_menu_append_section(submenu, nil,
                                          UnsafeMutablePointer<GMenuModel>(section))
                }
                g_object_unref(UnsafeMutableRawPointer(section))
            }
            for entry in entries {
                switch entry {
                case .separator:
                    finishSection()
                    section = g_menu_new()!
                case .item(let item):
                    let label: String
                    switch item.state {
                    case .checked(true), .selected: label = "✓ \(item.title)"
                    default: label = item.title
                    }
                    titles[item.identifier] = label
                    guard let command = item.command else {
                        g_menu_append(section, label, nil)
                        continue
                    }
                    commands[item.identifier] = command
                    let actionName = item.identifier.replacingOccurrences(of: ".", with: "-")
                    installAction(identifier: item.identifier, name: actionName)
                    if let action = actions[item.identifier] {
                        g_simple_action_set_enabled(action, item.enabled ? 1 : 0)
                    }
                    g_menu_append(section, label, "win.\(actionName)")
                }
            }
            finishSection()
            g_menu_append_submenu(model, title, UnsafeMutablePointer<GMenuModel>(submenu))
            g_object_unref(UnsafeMutableRawPointer(submenu))
        }
        appendToolsMenu()
    }

    private func appendToolsMenu() {
        let submenu = g_menu_new()!
        var section = g_menu_new()!
        var sectionTitle: String?
        func finishSection() {
            if g_menu_model_get_n_items(UnsafeMutablePointer<GMenuModel>(section)) > 0 {
                g_menu_append_section(submenu, sectionTitle,
                                      UnsafeMutablePointer<GMenuModel>(section))
            }
            g_object_unref(UnsafeMutableRawPointer(section))
        }
        for entry in CommandCatalog.toolsMenu(for: session, workspaceImageCount: 1) {
            switch entry {
            case .section(let heading):
                finishSection()
                section = g_menu_new()!
                sectionTitle = heading.title
            case .separator:
                finishSection()
                section = g_menu_new()!
                sectionTitle = nil
            case .item(let item):
                appendToolItem(item, to: section)
            }
        }
        finishSection()
        g_menu_append_submenu(model, "Tools", UnsafeMutablePointer<GMenuModel>(submenu))
        g_object_unref(UnsafeMutableRawPointer(submenu))
    }

    private func appendToolItem(_ item: ToolMenuItem, to menu: OpaquePointer) {
        guard item.visible else { return }
        titles[item.identifier] = item.title
        if !item.children.isEmpty {
            let submenu = g_menu_new()!
            for child in item.children { appendToolItem(child, to: submenu) }
            g_menu_append_submenu(menu, item.title, UnsafeMutablePointer<GMenuModel>(submenu))
            g_object_unref(UnsafeMutableRawPointer(submenu))
            return
        }
        guard let action = item.action else { return }
        toolActions[item.identifier] = action
        let actionName = item.identifier.replacingOccurrences(of: ".", with: "-")
        installAction(identifier: item.identifier, name: actionName)
        if let installed = actions[item.identifier] {
            g_simple_action_set_enabled(installed, item.enabled ? 1 : 0)
        }
        g_menu_append(menu, item.title, "win.\(actionName)")
    }

    private func installAction(identifier: String, name: String) {
        guard actions[identifier] == nil else { return }
        let action = g_simple_action_new(name, nil)!
        actionIDs[name] = identifier
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = {
            action, _, userData in
            guard let action, let userData else { return }
            let menu = Unmanaged<GTKCommandMenuBar>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let name = g_action_get_name(action).map(String.init(cString:)),
                      let identifier = menu.actionIDs[name] else { return }
                if let command = menu.commands[identifier] {
                    menu.onOutcome?(menu.session.perform(command, origin: .user))
                } else if let tool = menu.toolActions[identifier] {
                    menu.onToolAction?(tool)
                }
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKCommandMenuBar>.fromOpaque(userData).release()
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(action), "activate",
            unsafeBitCast(callback, to: GCallback.self), context, release,
            GConnectFlags(rawValue: 0)
        )
        g_action_map_add_action(OpaquePointer(window), action)
        actions[identifier] = action
        g_object_unref(UnsafeMutableRawPointer(action))
    }
}
