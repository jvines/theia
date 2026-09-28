import SwiftUI
import AppKit
import FITSCore
import TheiaKit

@main
struct FITSViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    AppDelegate.shared?.openDocumentAction(nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Open Remote…") {
                    AppDelegate.shared?.presentRemoteOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                if !BundledSamples.discover().isEmpty {
                    Menu("Open Sample") {
                        ForEach(BundledSamples.discover(), id: \.fileName) { sample in
                            Button(sample.title) {
                                AppDelegate.shared?.openDocument(at: sample.url)
                            }
                        }
                    }
                }
            }
            CommandGroup(after: .saveItem) {
                Button("Save Image as FITS…") {
                    AppDelegate.shared?.saveCurrentImageAsFITS()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .printItem) {
                Button("Page Setup…") {
                    NSApp.runPageLayout(nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Print…") {
                    AppDelegate.shared?.printFrontDocument()
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                ForEach(Array(CommandCatalog.workspaceMenu(
                    section: .app, for: WindowSyncCoordinator.shared.workspace
                ).enumerated()), id: \.offset) { _, entry in
                    if let item = entry.item {
                        if item.visible {
                            Button(item.title) {
                                AppDelegate.shared?.performWorkspaceCommand(item.command, origin: .user)
                            }
                            .help(item.tooltip)
                            .disabled(!item.enabled)
                        }
                    }
                }
            }
            CommandGroup(replacing: .help) {
                ForEach(Array(CommandCatalog.workspaceMenu(
                    section: .help, for: WindowSyncCoordinator.shared.workspace
                ).enumerated()), id: \.offset) { _, entry in
                    if let item = entry.item {
                        if item.visible {
                            Button(item.title) {
                                AppDelegate.shared?.performWorkspaceCommand(item.command, origin: .user)
                            }
                            .help(item.tooltip)
                            .disabled(!item.enabled)
                        }
                    } else {
                        Divider()
                    }
                }
            }
        }
    }
}
