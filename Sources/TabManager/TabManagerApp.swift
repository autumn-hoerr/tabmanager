import AppKit
import SwiftUI

@main
struct TabManagerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    private var library: Library { appDelegate.library }

    var body: some Scene {
        Window("Tab Manager", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 900, minHeight: 500)
        }
        Settings {
            SettingsView()
                .environment(library)
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save Changes") { Task { await library.saveAll() } }
                    .keyboardShortcut("s")
                    .disabled(library.dirtyItems.isEmpty)
                Button("Revert All Changes") { library.revertAll() }
                    .disabled(library.dirtyItems.isEmpty)
            }
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { library.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Reload") { library.reload() }
                    .keyboardShortcut("r")
                Divider()
                Button(library.selection.isEmpty ? "Organize All Files by Metadata…" : "Organize Selected Files by Metadata…") {
                    library.prepareOrganize()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(library.root == nil || library.isLoading)
                Divider()
                Button("Show Backups in Finder") { library.openBackups() }
                Button("Show Organize Logs in Finder") { library.openOrganizeLogs() }
            }
        }
    }
}

// Owns the Library (rather than @State) because the Command Line Tools toolchain
// ships without SwiftUI's macro plugins.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = Library()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !library.dirtyItems.isEmpty else { return .terminateNow }
        return library.confirmDiscard() ? .terminateNow : .terminateCancel
    }
}
