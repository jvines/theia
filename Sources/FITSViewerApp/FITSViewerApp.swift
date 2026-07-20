import SwiftUI
import AppKit
import FITSCore

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
                Button("About Theia") {
                    presentAboutPanel()
                }
            }
            CommandGroup(replacing: .help) {
                Button("Theia Documentation") {
                    NSWorkspace.shared.open(URL(string: "https://jvines.cl/fitsviewer")!)
                }
                Button("Source on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/jvines/fitsviewer")!)
                }
                Button("Report an Issue…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/jvines/fitsviewer/issues/new")!)
                }
                Divider()
                Button("HTTP Scripting Reference") {
                    AboutWindowController.showScriptingReference()
                }
                Divider()
                Button("Open Welcome Window") {
                    WelcomeWindowController.show()
                }
                Button("Show Onboarding") {
                    OnboardingWindowController.show()
                }
            }
        }
    }

    private func presentAboutPanel() {
        AboutWindowController.show()
    }
}
