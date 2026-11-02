import AppKit
import SwiftUI

@main
struct IMessagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    var body: some Scene {
        Window("iMessager", id: "main") {
            RootView()
                .environment(state)
                .frame(minWidth: Theme.minWindow.width, minHeight: Theme.minWindow.height)
        }
        .defaultSize(width: 1240, height: 800)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(state: state) }

        MenuBarExtra {
            MenuBarMenu().environment(state)
        } label: {
            // The logo's bubble; dimmed while iMessager can't read chat.db or has no AI connected.
            let active = state.hasDiskAccess && state.aiReady
            if let icon = Brand.menuBar {
                Image(nsImage: icon).opacity(active ? 1 : 0.45)
            } else {
                Image(systemName: active ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppState.shared.boot() }
    }

    /// Closing the window keeps the agent running from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.saveNow() }
        ChildProcesses.terminateAll()
    }
}

/// Every page lives in the menu bar and opens as a modal over the window.
struct AppCommands: Commands {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                openWindow(id: "main")
                NSApp.activate()
                state.modal = nil
                state.composing = true
            }
            .keyboardShortcut("n")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { show(.settings) }
                .keyboardShortcut(",")
        }
        CommandMenu("Agent") {
            Text(state.statusLine)
            Divider()
            Button("Activity") { show(.activity) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button("Integrations") { show(.integrations) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Divider()
            Button(state.needsSetup ? "Finish Setup…" : "Setup Checklist") { show(.setup) }
        }
    }

    private func show(_ modal: AppModal) {
        openWindow(id: "main")
        NSApp.activate()
        state.modal = modal
    }
}

struct MenuBarMenu: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        Text(state.statusLine)
        if state.needsSetup {
            Button("Finish setup…") {
                openWindow(id: "main")
                NSApp.activate()
                state.showChecklist = true
            }
        }
        Divider()
        Button("Activity") { show(.activity) }
        Button("Settings…") { show(.settings) }
        Divider()
        Button("Open iMessager") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Quit iMessager") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ modal: AppModal) {
        openWindow(id: "main")
        NSApp.activate()
        state.modal = modal
    }
}
