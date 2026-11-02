import AppKit
import SwiftUI

/// Pages open from the menu bar as a modal over the blurred app, like Arc.
enum AppModal: String, CaseIterable, Identifiable {
    case activity, integrations, settings, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .integrations: "Integrations"
        case .settings: "Settings"
        case .setup: "Setup Checklist"
        }
    }

    var icon: String {
        switch self {
        case .activity: "waveform.path.ecg"
        case .integrations: "puzzlepiece.extension"
        case .settings: "gearshape"
        case .setup: "checklist"
        }
    }
}

/// Laid out like Messages on macOS 26: conversations live in the floating sidebar, the chat fills the rest,
/// and there's no title bar text. Everything else lives in the menu bar and opens as a modal.
struct RootView: View {
    @Environment(AppState.self) private var state
    @State private var selection: String?
    /// A conversation you just started from New Message; opens as soon as it shows up in chat.db.
    @State private var startedChat: String?

    var body: some View {
        NavigationSplitView {
                ConversationList(selection: $selection)
                    // No sidebar toggle: like Messages, the sidebar always stays.
                    // (Width must come last, or SwiftUI falls back to its default sidebar width.)
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: Theme.sidebarMinWidth, ideal: Theme.sidebarWidth, max: Theme.sidebarMaxWidth)
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar {
                        // Where Messages keeps it: top left of the conversation.
                        ToolbarItem(placement: .navigation) {
                            Button {
                                selection = nil
                                state.composing = true
                            } label: {
                                Label("New Message", systemImage: "square.and.pencil")
                            }
                            .help("New Message (⌘N)")
                        }
                    }
            }
            .background(SidebarLock())
            .hidesWindowTitle()
            .overlay(alignment: .bottomTrailing) {
                // Bottom corner, like toasts, so they never cover the overview or a conversation's header.
                NoticeStack().padding(.bottom, 64)
            }
            // The modal and its blurred backdrop are a layer on top, animated on their own: blurring or animating
            // the app underneath re-lays out the open conversation and makes it scroll.
            .overlay { ModalLayer() }
        .onChange(of: selection) { _, id in
            if id != nil { state.composing = false }
        }
        .onChange(of: state.openRequest) { _, id in
            guard let id else { return }
            state.openRequest = nil
            state.modal = nil
            selection = id
        }
        .onChange(of: state.chats) {
            guard let key = startedChat, let chat = state.chats.first(where: { !$0.isGroup && ContactsIndex.sameHandle($0.id, key) }) else { return }
            startedChat = nil
            selection = chat.id
        }
    }

    @ViewBuilder private var detail: some View {
        if state.composing {
            NewMessageView(open: { id in
                selection = id
                state.composing = false
            }, started: { key in
                startedChat = key
            })
        } else if let id = selection, let chat = state.chats.first(where: { $0.id == id }) {
            ChatDetailView(chat: chat).id(id)
        } else {
            HomeView()
        }
    }
}

/// Arc-style: the app blurred and dimmed behind a page in the middle of the window. Click outside or press Esc to close.
private struct ModalLayer: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            if let modal = state.modal {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.22))
                    .ignoresSafeArea()
                    .onTapGesture { state.modal = nil }
                    .transition(.opacity)
                ModalCard(modal: modal)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: state.modal)
    }
}

/// A page floating in the middle of the window.
private struct ModalCard: View {
    @Environment(AppState.self) private var state
    let modal: AppModal

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            VStack(spacing: 0) {
                if modal != .setup {
                    HStack(spacing: 10) {
                        Image(systemName: modal.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(modal.title).font(.title3.weight(.semibold))
                        Spacer()
                        Button { state.modal = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 16, height: 16)
                        }
                        .glassButtonStyle()
                        .buttonBorderShape(.circle)
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    Divider().opacity(0.6)
                }
                Group {
                    switch modal {
                    case .activity: ActivityView()
                    case .integrations: IntegrationsView()
                    case .settings: SettingsView()
                    case .setup: SetupChecklist()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: min(780, geo.size.width - 80), height: min(modal == .setup ? 660 : 680, geo.size.height - 60))
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.82), in: shape)
            .liquidGlass(in: shape)
            .clipShape(shape)
            .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension View {
    /// No title and no toolbar bar, like Messages: just glass controls floating over the content.
    @ViewBuilder
    func hidesWindowTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title).toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            navigationTitle("")
        }
    }
}

/// Like Messages, dragging the sidebar narrower stops at its minimum width instead of collapsing it.
struct SidebarLock: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    final class Probe: NSView {
        private weak var lockedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            lockedWindow = nil
            apply()
        }

        /// Walks the window's views to find the split view, so it runs once per window, not on every SwiftUI update.
        func apply() {
            guard lockedWindow == nil || lockedWindow !== window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, let content = window.contentView else { return }
                var locked = false
                for split in Self.splitViews(in: content) {
                    guard let item = (split.delegate as? NSSplitViewController)?.splitViewItems.first else { continue }
                    item.canCollapse = false
                    item.canCollapseFromWindowResize = false
                    locked = true
                }
                if locked { self.lockedWindow = window }
            }
        }

        private static func splitViews(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews)
        }
    }
}


extension AppState {
    var agentStatus: (text: String, color: Color) {
        if dbAccess == .checking { return ("Checking…", .secondary) }
        if !hasDiskAccess { return ("Can't read chat.db", .red) }
        if !aiReady { return (config.provider == .claudeCode ? "Claude Code not ready" : "Needs API key", .orange) }
        if config.dryRun { return ("Dry run", .yellow) }
        return ("Listening", .green)
    }
}

struct AgentStatusCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let status = state.agentStatus
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .shadow(color: status.color.opacity(0.7), radius: 3)
                Text(status.text)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            Text(state.config.model)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 0) {
                stat("bolt.fill", "\(state.enabledCount) on auto-reply")
                Spacer(minLength: 4)
                stat("paperplane.fill", "\(state.sentCount) sent")
                if let ms = state.lastLatency {
                    Spacer(minLength: 4)
                    stat("timer", "\(ms) ms")
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}
