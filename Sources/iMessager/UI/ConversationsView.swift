import AppKit
import ImageIO
import PhotosUI
import SwiftUI
import Vision

/// Messages' own filters, plus iMessager's auto-reply view.
enum ChatFilter: String, CaseIterable, Identifiable {
    case messages, unread, known, unknown, groups, transactions, promotions, autoReply, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "Messages"
        case .unread: "Unread"
        case .known: "Known Senders"
        case .unknown: "Unknown Senders"
        case .groups: "Group Chats"
        case .transactions: "Transactions"
        case .promotions: "Promotions"
        case .autoReply: "Auto-reply On"
        case .all: "All Conversations"
        }
    }

    var icon: String {
        switch self {
        case .messages: "message"
        case .unread: "circlebadge"
        case .known: "person.crop.circle.badge.checkmark"
        case .unknown: "person.crop.circle.badge.questionmark"
        case .groups: "person.2"
        case .transactions: "creditcard"
        case .promotions: "megaphone"
        case .autoReply: "bolt"
        case .all: "tray.full"
        }
    }

    @MainActor func matches(_ chat: ChatSummary, _ state: AppState) -> Bool {
        switch self {
        case .messages: state.inMainList(chat)
        case .unread: chat.unread > 0
        case .known: chat.isKnown && !chat.isGroup && chat.kind == .person
        case .unknown: !chat.isKnown && chat.kind == .person
        case .groups: chat.isGroup
        case .transactions: chat.kind == .transaction
        case .promotions: chat.kind == .promotion
        case .autoReply: state.isEnabled(chat.id)
        case .all: true
        }
    }
}

/// The floating sidebar, like Messages: filter on top, then search, pins and conversations.
struct ConversationList: View {
    @Environment(AppState.self) private var state
    @Binding var selection: String?
    @State private var query = ""
    @State private var filter: ChatFilter = .messages

    private var filtered: [ChatSummary] {
        state.chats.filter { chat in
            guard filter.matches(chat, state) else { return false }
            guard !query.isEmpty else { return true }
            return chat.title.localizedCaseInsensitiveContains(query) || chat.id.localizedCaseInsensitiveContains(query)
                || chat.preview.localizedCaseInsensitiveContains(query)
        }
    }

    /// Pins sit on top of the main list, like Messages.
    private var pinned: [ChatSummary] {
        guard filter == .messages, query.isEmpty else { return [] }
        return state.chats.filter(\.isPinned).sorted { $0.pin! < $1.pin! }
    }

    var body: some View {
        let pins = pinned
        let rows = filtered.filter { pins.isEmpty || !$0.isPinned }
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Search")
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
            if state.dbAccess == .checking || (state.hasDiskAccess && !state.chatsLoaded) {
                ListSkeleton()
            } else {
            List(selection: $selection) {
                if !pins.isEmpty {
                    PinnedGrid(chats: pins, selection: $selection)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 6, trailing: 4))
                        .selectionDisabled()
                }
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, chat in
                        ChatRow(chat: chat, separator: i > 0)
                            .tag(chat.id)
                    }
                } header: {
                    if filter != .messages {
                        Label(filter.title, systemImage: filter.icon)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay { if rows.isEmpty && pins.isEmpty { emptyState } }
            }
        }
        .toolbar {
            // Right edge of the sidebar, like Messages' filter button; the traffic lights keep the left.
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem {
                HomeButton(active: selection == nil && !state.composing) {
                    selection = nil
                    state.composing = false
                }
            }
            ToolbarItem {
                FilterMenu(filter: $filter)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if state.hasDiskAccess {
            ContentUnavailableView(query.isEmpty ? "Nothing here" : "No matches", systemImage: "magnifyingglass",
                                   description: Text(filter == .messages ? "Try a different search." : "Try another filter."))
        } else {
            ContentUnavailableView {
                Label("Can't read your messages yet", systemImage: "lock.shield")
            } description: {
                Text(state.dbAccess == .checking ? "Checking access to chat.db…" : "iMessager needs your permission to read chat.db.")
            } actions: {
                Button("Show me how") { state.showChecklist = true }
                    .glassButtonStyle(prominent: true)
            }
        }
    }
}

/// Home: blue and filled while the overview is showing, plain otherwise.
private struct HomeButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if active {
                Button(action: action) { Label("Home", systemImage: "house.fill") }
                    .glassButtonStyle(prominent: true)
                    .tint(.accentColor)
            } else {
                Button(action: action) { Label("Home", systemImage: "house") }
            }
        }
        .labelStyle(.iconOnly)
        .help(active ? "Home" : "Home: your overview")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Just the filter icon, like Messages. The menu holds Messages' categories with live counts.
private struct FilterMenu: View {
    @Environment(AppState.self) private var state
    @Binding var filter: ChatFilter

    var body: some View {
        Menu {
            Text(summary)
            Picker("Show", selection: $filter) {
                Section { item(.messages); item(.unread) }
                Section("People") { item(.known); item(.unknown); item(.groups) }
                Section("Filtered") { item(.transactions); item(.promotions) }
                Section { item(.autoReply); item(.all) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter", systemImage: filter == .messages ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuIndicator(.hidden)
        .help("Filter: \(filter.title)")
    }

    private var summary: String {
        ["\(state.chats.count) conversations", state.unreadCount > 0 ? "\(state.unreadCount) unread" : nil,
         "\(state.enabledCount) on auto-reply"].compactMap { $0 }.joined(separator: " · ")
    }

    private func item(_ f: ChatFilter) -> some View {
        let count = state.chats.filter { f.matches($0, state) }.count
        return Label(count > 0 && f != .messages && f != .all ? "\(f.title)  \(count)" : f.title, systemImage: f.icon).tag(f)
    }
}

/// Pinned conversations as large avatars, three across, like Messages.
private struct PinnedGrid: View {
    let chats: [ChatSummary]
    @Binding var selection: String?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(chats) { chat in
                PinnedItem(chat: chat, selected: selection == chat.id) { selection = chat.id }
            }
        }
    }
}

private struct PinnedItem: View {
    let chat: ChatSummary
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Avatar(title: chat.title, isGroup: chat.isGroup, active: false, size: 62, handle: chat.photoHandle,
                       photoPath: chat.photoPath, members: chat.participants)
                    .overlay(alignment: .topLeading) {
                        // New messages: a blue dot on the photo.
                        if chat.unread > 0 {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2.5))
                                .offset(x: 1, y: 1)
                                .help("\(chat.unread) new")
                        }
                    }
                HStack(spacing: 4) {
                    Text(chat.title)
                        .font(.system(size: 11, weight: chat.unread > 0 ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(selected ? Color.white : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(chat.title)
        .contextMenu {
            if chat.unread > 0 {
                Button("Mark as Read") { AppState.shared.markRead(chat.id) }
            } else {
                Button("Mark as Unread") { AppState.shared.markUnread(chat.id) }
            }
        }
    }

    private var background: Color {
        if selected { return .accentColor }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}

struct ChatRow: View {
    @Environment(AppState.self) private var state
    let chat: ChatSummary
    var separator = false

    /// "You: …" isn't shown in Messages; in groups, who said it is.
    private var previewText: String {
        if chat.isGroup, !chat.lastFromMe, let sender = chat.lastSender {
            // First names for contacts; the whole number for people you haven't saved.
            let name = state.contacts.name(for: sender).flatMap { $0.split(separator: " ").first.map(String.init) }
                ?? ContactsIndex.pretty(sender)
            return name + ": " + chat.preview
        }
        return chat.preview
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(chat.unread > 0 ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 17)
            Avatar(title: chat.title, isGroup: chat.isGroup, active: state.isEnabled(chat.id), size: 40,
                   handle: chat.photoHandle, photoPath: chat.photoPath, members: chat.participants)
                .padding(.trailing, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !chat.isKnown && chat.kind == .person && !chat.isGroup { Tag("NEW") }
                    Spacer(minLength: 4)
                    if chat.lastFailed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .help("Not Delivered")
                    }
                    Text(Fmt.short(chat.lastDate))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // Several unread texts: an AI one-liner with the summary glyph, like Messages.
                if chat.unread > 0, let summary = state.summaries[chat.id] {
                    (Text(Image(systemName: "text.append")) + Text(" ") + Text(summary))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .help("Summary of \(chat.unread) unread messages")
                } else {
                    Text(previewText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            if separator {
                Divider().padding(.leading, 64).offset(y: -1)
            }
        }
        .contentShape(Rectangle())
        .help(chat.isGroup ? "\(chat.title) · group of \(chat.participants.count + 1)" : chat.title)
        .contextMenu {
            if chat.unread > 0 {
                Button("Mark as Read") { state.markRead(chat.id) }
            } else {
                Button("Mark as Unread") { state.markUnread(chat.id) }
            }
            Toggle("Auto-reply", isOn: state.enabledBinding(chat.id))
            Divider()
            if chat.kind != .person {
                Button("Move to Messages") { state.setKind(.person, for: chat.id) }
            }
            if chat.kind != .transaction {
                Button("Move to Transactions") { state.setKind(.transaction, for: chat.id) }
            }
            if chat.kind != .promotion {
                Button("Move to Promotions") { state.setKind(.promotion, for: chat.id) }
            }
            if state.config.chatKinds[chat.id] != nil {
                Button("Sort Automatically") { state.setKind(nil, for: chat.id) }
            }
        }
    }
}

struct ChatDetailView: View {
    @Environment(AppState.self) private var state
    let chat: ChatSummary
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var info = ""
    @State private var working = false
    @State private var deleting: ChatMessage?
    @State private var lastDeleted: ChatMessage?
    @State private var showDetails = false
    @State private var loaded = false
    @State private var attachments: [URL] = []
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?
    @State private var positioned = false
    @State private var typingOut = false
    /// Messages that inline replies answer but that are older than what's loaded.
    @State private var originals: [String: ChatMessage] = [:]
    @State private var openThread: String?
    @State private var viewingMedia: URL?
    @State private var highlighted: String?
    @State private var revealed = false
    @FocusState private var composerFocused: Bool

    private var handle: String? { chat.isGroup ? nil : chat.id }
    private var canText: Bool { !chat.isGroup && !chat.id.contains("@") }

    var body: some View {
        transcript
            .toolbar {
                ToolbarItem(placement: .principal) { titlePill }
                ToolbarItem(placement: .primaryAction) { autoReplyButton }
            }
            .overlay {
                if let url = viewingMedia {
                    MediaViewer(url: url) { viewingMedia = nil }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: viewingMedia)
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task {
                    for item in items {
                        if let picked = try? await item.loadTransferable(type: PickedFile.self) { attachments.append(picked.url) }
                    }
                    composerFocused = true
                }
            }
            // Drop photos, videos or files anywhere on the conversation.
            .onDrop(of: [.fileURL, .image, .movie], isTargeted: $dropTargeted) { providers in
                Incoming.fromDrop(providers) { attachments.append($0) }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay { Label("Drop to attach", systemImage: "paperclip").font(.headline).foregroundStyle(Color.accentColor) }
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            // ⌘V with a photo or file on the clipboard attaches it; plain text pastes as usual.
            .onAppear {
                state.viewingChat = chat.id
                pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard composerFocused, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v",
                          let files = Incoming.fromPasteboard() else { return event }
                    attachments.append(contentsOf: files)
                    return nil
                }
            }
            .onDisappear {
                if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
                if state.viewingChat == chat.id { state.viewingChat = nil }
            }
            .task(id: state.revision) {
            // Re-read on every chat.db change (receipts included), but only re-render when something actually changed.
            let fresh = await state.history(chat.id, limit: 80)
            if fresh != messages { messages = fresh }
            let loadedGuids = Set(fresh.map(\.guid))
            let missing = Set(fresh.compactMap(\.threadOriginator)).subtracting(loadedGuids).subtracting(originals.keys)
            if !missing.isEmpty, let found = try? await state.db.messages(guids: Array(missing)) {
                originals.merge(found) { $1 }
            }
            loaded = true
            // Looking at it counts as reading it, as in Messages (only while iMessager is the app in front).
            if NSApp.isActive { state.markRead(chat.id, through: fresh.last?.date) }
        }
        .task(id: lastDeleted?.id) {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { lastDeleted = nil }
        }
        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { m in
            Button("Delete", role: .destructive) {
                state.hide(m)
                lastDeleted = m
            }
        } message: { _ in
            Text("It's removed from iMessager and from what the AI sees. Messages doesn't let other apps delete texts, so it stays in Messages on your devices.")
        }
    }

    // MARK: Header (in the toolbar, like Messages)

    private var subtitle: String {
        chat.isGroup ? "\(chat.participants.count + 1) people" : ContactsIndex.pretty(chat.id)
    }

    /// Avatar and name, centered. Click for details: members, auto-reply, AI instructions, sorting.
    private var titlePill: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 7) {
                Avatar(title: chat.title, isGroup: chat.isGroup, size: 24, handle: chat.photoHandle, photoPath: chat.photoPath,
                       members: chat.participants)
                Text(chat.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: 360)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(chat.title) · \(subtitle) · \(chat.service)")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            ChatDetails(chat: chat)
        }
    }

    /// The logo of the AI that writes replies: in color when auto-reply is on for this chat, gray when it's off.
    private var autoReplyButton: some View {
        let on = state.isEnabled(chat.id)
        let provider = state.config.provider
        let name = provider == .claudeCode ? "Claude" : "OpenRouter"
        return Button {
            state.setEnabled(chat.id, !on)
        } label: {
            Label {
                Text(on ? "Auto-reply On" : "Auto-reply Off")
            } icon: {
                if let logo = Brand.providerLogo(provider) {
                    Image(nsImage: logo).renderingMode(.template)
                } else {
                    Image(systemName: "bolt.fill")
                }
            }
            .foregroundStyle(on ? Brand.providerColor(provider) : Color.secondary.opacity(0.6))
        }
        .help(on ? "Auto-reply is on: \(name) answers this conversation for you. Click to turn it off."
              : "Auto-reply is off. Click to let \(name) answer this conversation.")
        .accessibilityLabel(on ? "Auto-reply On" : "Auto-reply Off")
    }

    // MARK: Transcript

    /// Outbox texts that chat.db doesn't have yet. A sent one gives way as soon as its chat.db copy lands.
    private func pending(after shown: [ChatMessage]) -> [OutgoingMessage] {
        state.outbox(for: chat.id).filter { item in
            guard item.phase == .sent else { return true }
            let cutoff = item.created.addingTimeInterval(-5)
            return !shown.contains { $0.isFromMe && $0.date >= cutoff && $0.text == item.text.trimmed }
        }
    }

    private var transcript: some View {
        let shown = messages.filter { !state.isHidden($0) }
        let queue = pending(after: shown)
        let lastMine = shown.last(where: { $0.isFromMe && !$0.isRetracted })?.id
        return ScrollViewReader { proxy in
            // Built only once the messages are in, so it opens at the newest message rather than mid-thread.
            if loaded { scroll(shown, queue, lastMine, proxy) } else { TranscriptSkeleton() }
        }
        .floatingBar(.bottom) { composer }
    }

    private func scroll(_ shown: [ChatMessage], _ queue: [OutgoingMessage], _ lastMine: Int64?, _ proxy: ScrollViewProxy) -> some View {
            ScrollView {
                // A plain VStack: 80 bubbles lay out instantly, and exact heights keep the bottom anchor reliable.
                VStack(spacing: 4) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || m.date.timeIntervalSince(shown[i - 1].date) > 3600 {
                            Text(m.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, i == 0 ? 0 : 14)
                                .padding(.bottom, 4)
                        }
                        row(m, previous: i > 0 ? shown[i - 1] : nil, next: i + 1 < shown.count ? shown[i + 1] : nil,
                            showStatus: m.id == lastMine && queue.isEmpty)
                            .background(highlighted == m.guid ? Color.accentColor.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .animation(.easeOut(duration: 0.25), value: highlighted)
                            .modifier(Reveal(order: shown.count - 1 - i, on: revealed))
                            .id(m.guid)
                    }
                    ForEach(queue) { pendingRow($0) }
                    if state.replying[chat.id] != nil {
                        HStack {
                            Spacer()
                            TypingBubble()
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomTrailing)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .staysAtBottom()
            .softScrollEdge(.bottom)
            // Hidden for a beat until it's sitting on the newest message, so opening a thread never shows a jump.
            .opacity(positioned ? 1 : 0)
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        positioned = true
                        revealed = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: shown.last?.id) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: queue.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: state.replying[chat.id] != nil) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .overlay {
                if shown.isEmpty && queue.isEmpty {
                    Text("No messages to show").font(.callout).foregroundStyle(.tertiary)
                }
            }
            // Threads like Messages: the conversation blurs and only that thread's messages show, in place.
            .overlay { threadOverlay(proxy) }
            .animation(.spring(duration: 0.3, bounce: 0.15), value: openThread)
    }

    @ViewBuilder
    private func row(_ m: ChatMessage, previous: ChatMessage?, next: ChatMessage?, showStatus: Bool) -> some View {
        if chat.isGroup && !m.isFromMe && !m.isRetracted {
            // In groups, the sender's face sits beside the last bubble of each run, like Messages.
            let endOfRun = next == nil || next?.isFromMe == true || next?.sender != m.sender || next?.isRetracted == true
            HStack(alignment: .bottom, spacing: 6) {
                if endOfRun {
                    Avatar(title: name(of: m), size: 26, handle: m.sender)
                        .help(name(of: m))
                } else {
                    Color.clear.frame(width: 26, height: 1)
                }
                message(m, previous: previous, showStatus: showStatus)
            }
        } else {
            message(m, previous: previous, showStatus: showStatus)
        }
    }

    @ViewBuilder
    private func message(_ m: ChatMessage, previous: ChatMessage?, showStatus: Bool) -> some View {
        if m.isRetracted {
            Text(m.isFromMe ? "You unsent a message" : "\(name(of: m)) unsent a message")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else if !m.attachments.isEmpty {
            VStack(alignment: m.isFromMe ? .trailing : .leading, spacing: 4) {
                ForEach(m.attachments) { a in
                    HStack(spacing: 0) {
                        if m.isFromMe { Spacer(minLength: 90) }
                        AttachmentView(a) { viewingMedia = $0 }
                            .contextMenu {
                                AttachmentActions(url: URL(fileURLWithPath: a.path))
                                Divider()
                                Button("Delete…", role: .destructive) { deleting = m }
                            }
                        if !m.isFromMe { Spacer(minLength: 90) }
                    }
                }
                if !m.caption.isEmpty {
                    textBubble(m, text: m.caption, previous: previous, showStatus: showStatus)
                } else if let status = m.status, showStatus || status == .failed {
                    Text(status.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(status == .failed ? Color.red : Color.secondary)
                        .padding(.horizontal, 6)
                }
            }
        } else {
            textBubble(m, text: m.text, previous: previous, showStatus: showStatus)
        }
    }

    /// The message an inline reply answers, from what's loaded or fetched by guid.
    private func original(of m: ChatMessage) -> ChatMessage? {
        guard let guid = m.threadOriginator else { return nil }
        return messages.first { $0.guid == guid } ?? originals[guid]
    }

    @ViewBuilder
    private func threadOverlay(_ proxy: ScrollViewProxy) -> some View {
        if let thread = openThread {
            ThreadOverlay(root: messages.first { $0.guid == thread } ?? originals[thread],
                          replies: messages.filter { $0.threadOriginator == thread },
                          name: { name(of: $0) },
                          onMedia: { viewingMedia = $0 },
                          close: { openThread = nil }) {
                // Click the original: back to it in the conversation, briefly highlighted.
                openThread = nil
                guard messages.contains(where: { $0.guid == thread }) else { return }
                withAnimation { proxy.scrollTo(thread, anchor: .center) }
                highlighted = thread
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if highlighted == thread { highlighted = nil } }
            }
            .transition(.opacity)
        }
    }

    private func replyCount(_ m: ChatMessage) -> Int {
        messages.filter { $0.threadOriginator == m.guid }.count
    }

    private func reactionNote(_ m: ChatMessage) -> String {
        m.reactions.map { r in
            let who = r.fromMe ? "You" : (r.sender.map { state.contacts.name(for: $0) ?? ContactsIndex.pretty($0) } ?? "Someone")
            return "\(who) \(r.verb) this"
        }.joined(separator: "\n")
    }

    @ViewBuilder
    private func textBubble(_ m: ChatMessage, text: String, previous: ChatMessage?, showStatus: Bool) -> some View {
        VStack(alignment: m.isFromMe ? .trailing : .leading, spacing: 2) {
            // An inline reply shows a faint quote of what it answers; click it to see the whole thread.
            if let quoted = original(of: m) {
                ReplyQuote(message: quoted, fromMe: m.isFromMe, name: quoted.isFromMe ? "You" : name(of: quoted)) {
                    openThread = quoted.guid
                }
            }
            plainBubble(m, text: text, previous: previous, showStatus: showStatus)
            let replies = replyCount(m)
            if replies > 0 {
                HStack {
                    if m.isFromMe { Spacer() }
                    Button("\(replies) \(replies == 1 ? "Reply" : "Replies")") { openThread = m.guid }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                    if !m.isFromMe { Spacer() }
                }
            }
        }

    }

    @ViewBuilder
    private func plainBubble(_ m: ChatMessage, text: String, previous: ChatMessage?, showStatus: Bool) -> some View {
        do {
            let link = Linkify.cached(text).url
            Bubble(text: text, fromMe: m.isFromMe, green: m.isTextMessage, sender: senderName(m, previous: previous),
                   failed: m.status == .failed, tooltip: tooltip(m),
                   // Like Messages, unknown senders don't get rich links: fetching one would tell the sender's server you looked.
                   preview: m.isFromMe || chat.isKnown ? link : nil, reactions: m.reactions, reactionNote: reactionNote(m)) {
                if m.status == .failed {
                    Text("Not Delivered").foregroundStyle(.red)
                } else if showStatus, let status = m.status {
                    Text((m.isEdited ? "Edited · " : "") + status.label)
                } else if m.isEdited {
                    Text("Edited")
                }
            } actions: {
                if m.status == .failed {
                    Button("Try Again") { state.resend(m, guid: chat.guid, handle: handle, asTextMessage: false) }
                    if canText {
                        Button("Send as Text Message") { state.resend(m, guid: chat.guid, handle: handle, asTextMessage: true) }
                    }
                    Divider()
                }
                if let link {
                    Button("Open Link") { NSWorkspace.shared.open(link) }
                    Button("Copy Link") { copy(link.absoluteString) }
                }
                Button("Copy") { copy(m.text) }
                Divider()
                // Messages has no way for other apps to send tapbacks or threaded replies, so these hand off to it.
                Button("React in Messages") { openInMessages() }
                Button("Reply in Messages") { openInMessages() }
                if replyCount(m) > 0 || m.threadOriginator != nil {
                    Button("Show Thread") { openThread = m.threadOriginator ?? m.guid }
                }
                Divider()
                Button("Delete…", role: .destructive) { deleting = m }
            }
        }
    }

    @ViewBuilder
    private func pendingRow(_ item: OutgoingMessage) -> some View {
        if let file = item.attachment {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 0) {
                    Spacer(minLength: 90)
                    AttachmentView(file: file) { viewingMedia = $0 }
                        .opacity(item.phase == .queued || item.phase == .sending ? 0.6 : 1)
                        .contextMenu {
                            if item.phase == .queued { Button("Undo Send") { undo(item) } }
                            if item.isFailed { Button("Try Again") { state.retry(item.id, asTextMessage: false) } }
                            AttachmentActions(url: file)
                            if item.phase == .queued || item.isFailed {
                                Divider()
                                Button("Delete", role: .destructive) { state.discard(item.id) }
                            }
                        }
                }
                PendingStatus(item: item) { undo(item) }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        } else {
            pendingTextRow(item)
        }
    }

    private func pendingTextRow(_ item: OutgoingMessage) -> some View {
        Bubble(text: item.text, fromMe: true, green: item.asTextMessage || chat.service == "SMS",
               faded: item.phase == .queued || item.phase == .sending, failed: item.isFailed,
               tooltip: item.isFailed ? item.phaseLabel : nil) {
            PendingStatus(item: item) { undo(item) }
        } actions: {
            if item.isFailed {
                Button("Try Again") { state.retry(item.id, asTextMessage: false) }
                if canText {
                    Button("Send as Text Message") { state.retry(item.id, asTextMessage: true) }
                }
                Divider()
            }
            if item.phase == .queued {
                Button("Undo Send") { undo(item) }
            }
            Button("Copy") { copy(item.text) }
            if item.phase == .queued || item.isFailed {
                Divider()
                Button("Delete", role: .destructive) { state.discard(item.id) }
            }
        }
    }

    /// Sender labels in group chats, only when the speaker changes.
    private func senderName(_ m: ChatMessage, previous: ChatMessage?) -> String? {
        guard chat.isGroup, !m.isFromMe, m.sender != nil, previous?.sender != m.sender || previous?.isFromMe == true else { return nil }
        return name(of: m)
    }

    private func name(of m: ChatMessage) -> String {
        guard chat.isGroup else { return chat.title }
        return m.sender.map { state.contacts.name(for: $0) ?? ContactsIndex.pretty($0) } ?? "Someone"
    }

    private func tooltip(_ m: ChatMessage) -> String {
        let when = m.date.formatted(date: .abbreviated, time: .shortened)
        guard let status = m.status else { return when }
        return "\(when) · \(m.isTextMessage ? "Text Message" : "iMessage") · \(status.label)"
    }

    private func undo(_ item: OutgoingMessage) {
        guard let back = state.undoSend(item.id) else { return }
        if let file = back.attachment {
            attachments.append(file)
        } else if draft.trimmed.isEmpty {
            draft = back.text
        }
        composerFocused = true
    }

    /// Opens this conversation in Messages (for a group, just Messages: there's no link to a group).
    private func openInMessages() {
        let url = chat.isGroup ? URL(string: "messages://") : URL(string: (chat.id.contains("@") ? "imessage:" : "sms:") + chat.id)
        if let url { NSWorkspace.shared.open(url) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Composer

    /// Floats over the transcript in Liquid Glass, like Messages on macOS 26.
    private var composer: some View {
        VStack(spacing: 8) {
            if let deleted = lastDeleted {
                HStack(spacing: 8) {
                    Label("Message deleted from iMessager", systemImage: "trash")
                    Button("Undo") {
                        state.unhide(deleted)
                        lastDeleted = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
                }
                .toast()
            } else if !info.isEmpty, !working {
                Label(info, systemImage: "sparkles").toast()
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(attachments, id: \.self) { url in
                            AttachmentChip(url: url) { attachments.removeAll { $0 == url } }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, 6)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            GlassGroup(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    // Photos and files, like the + in Messages. Paste and drag-and-drop work too.
                    Button {
                        PopupMenu.show([
                            ("Photos…", "photo.on.rectangle", { showPhotos = true }),
                            ("Files…", "folder", { chooseFiles() }),
                        ])
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .glassCircleButton()
                    .help("Add photos, videos or files")

                    Button {
                        Task { await generate() }
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .symbolEffect(.variableColor.iterative.reversing, isActive: working)
                            .foregroundStyle(working ? Color.purple : Color.primary)
                            .frame(width: 20, height: 20)
                    }
                    .glassCircleButton()
                    .disabled(working)
                    .help("Draft a reply with AI (doesn't send)")

                    TextField(aiBusy ? "" : (chat.service == "SMS" ? "Text Message" : "iMessage"), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .disabled(aiBusy || typingOut)
                        .overlay(alignment: .leading) {
                            if aiBusy && draft.isEmpty { AIStatusLine(provider: state.config.provider, verb: working ? "drafting" : "replying") }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(minHeight: 36)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
                        .onSubmit { send() }

                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 20, height: 20)
                    }
                    .glassCircleButton(prominent: true)
                    .tint(chat.service == "SMS" ? .green : .accentColor)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend || aiBusy || typingOut)
                    .overlay {
                        // While the AI writes, the send button becomes Stop.
                        if state.replying[chat.id] != nil && !working {
                            Button { Task { await state.stopReplying(chat.id) } } label: {
                                Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).frame(width: 20, height: 20)
                            }
                            .glassCircleButton(prominent: true)
                            .tint(.red)
                            .help("Stop \(state.providerName) and reply yourself")
                        }
                    }
                    .contextMenu {
                        Button("Send as Text Message") { send(asTextMessage: true) }
                            .disabled(!canSend || !canText)
                    }
                    .help(undoHint)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var canSend: Bool { !working && (!draft.trimmed.isEmpty || !attachments.isEmpty) }

    /// The AI is writing in this conversation (an auto-reply, or a ✨ draft), so the text bar is locked.
    private var aiBusy: Bool { working || state.replying[chat.id] != nil }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls
        Task.detached(priority: .userInitiated) {
            let staged = picked.compactMap { try? Staging.stage($0) }
            await MainActor.run { attachments.append(contentsOf: staged) }
        }
    }

    private var undoHint: String {
        let seconds = Int(state.config.undoSendSeconds)
        return "Send (↩). Right-click to send as a text message." + (seconds > 0 ? " You can undo for \(seconds)s." : "")
    }

    private func generate() async {
        working = true
        defer { working = false }
        do {
            let d = try await state.preview(chat.id)
            await typeOut(d.text ?? "")
            info = d.text == nil
                ? "The AI wouldn't reply here · \(d.ms) ms"
                : "Drafted in \(d.ms) ms" + (d.tools.isEmpty ? "" : " · used \(Array(Set(d.tools)).sorted().joined(separator: ", "))")
        } catch {
            info = error.localizedDescription
        }
    }

    /// The draft appears as if it's being typed, a few characters at a time (well under a second for a normal text).
    private func typeOut(_ text: String) async {
        typingOut = true
        defer { typingOut = false }
        draft = ""
        let step = max(1, text.count / 45)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: step, limitedBy: text.endIndex) ?? text.endIndex
            draft += text[index..<next]
            index = next
            try? await Task.sleep(for: .milliseconds(14))
        }
        composerFocused = true
    }

    private func send(asTextMessage: Bool = false) {
        let text = draft.trimmed
        let files = attachments
        guard !text.isEmpty || !files.isEmpty, !working else { return }
        draft = ""
        info = ""
        attachments = []
        Task { await state.send(text, to: chat, attachments: files, asTextMessage: asTextMessage) }
    }
}

/// One tapback, as a small bubble.
struct ReactionBadge: View {
    let reaction: Reaction

    var body: some View {
        Group {
            switch reaction.kind {
            case .emoji(let e):
                Text(e).font(.system(size: 13))
            case .laugh:
                Text("HA\nHA").font(.system(size: 6.5, weight: .heavy)).multilineTextAlignment(.center).lineSpacing(-2)
            default:
                Image(systemName: reaction.symbol ?? "heart.fill").font(.system(size: 10.5, weight: .bold))
            }
        }
        .foregroundStyle(reaction.fromMe ? Color.white : Color.secondary)
        .frame(width: 26, height: 26)
        .background {
            ZStack {
                Circle().fill(Color(nsColor: .windowBackgroundColor))
                Circle().fill(reaction.fromMe ? Color.accentColor : Color.primary.opacity(0.18))
            }
        }
        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

/// Above an inline reply: who and what it answers, faint, with the connecting curve Messages draws.
private struct ReplyQuote: View {
    let message: ChatMessage
    let fromMe: Bool
    let name: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if fromMe { Spacer(minLength: 120) }
            Button(action: open) {
                HStack(alignment: .bottom, spacing: 6) {
                    if fromMe { quote; curve.scaleEffect(x: -1) } else { curve; quote }
                }
            }
            .buttonStyle(.plain)
            .help("Show thread")
            if !fromMe { Spacer(minLength: 120) }
        }
    }

    private var quote: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(message.caption.isEmpty ? (message.attachments.first?.label ?? "Message") : message.caption)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .opacity(0.85)
    }

    private var curve: some View {
        Path { p in
            p.move(to: CGPoint(x: 10, y: 0))
            p.addQuadCurve(to: CGPoint(x: 2, y: 16), control: CGPoint(x: 2, y: 2))
        }
        .stroke(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 12, height: 18)
    }
}

/// Messages' thread view: the conversation blurs, and only the original and its replies show in its place.
/// Click the original to go back to it in the conversation; click outside or press Esc to close.
private struct ThreadOverlay: View {
    let root: ChatMessage?
    let replies: [ChatMessage]
    let name: (ChatMessage) -> String
    let onMedia: (URL) -> Void
    let close: () -> Void
    let jump: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            ScrollView {
                VStack(spacing: 6) {
                    if let root {
                        bubble(root)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: jump)
                            .help("Show in conversation")
                    }
                    ForEach(replies) { bubble($0) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture(perform: close))
            }
            .defaultScrollAnchor(.bottom)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 18, height: 18)
            }
            .glassCircleButton()
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .padding(14)
        }
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        VStack(alignment: m.isFromMe ? .trailing : .leading, spacing: 4) {
            ForEach(m.attachments) { a in
                HStack(spacing: 0) {
                    if m.isFromMe { Spacer(minLength: 90) }
                    AttachmentView(a, onOpen: onMedia)
                    if !m.isFromMe { Spacer(minLength: 90) }
                }
            }
            if !m.caption.isEmpty || m.attachments.isEmpty {
                Bubble(text: m.caption, fromMe: m.isFromMe, green: m.isTextMessage, sender: m.isFromMe ? nil : name(m),
                       reactions: m.reactions) {
                    Text(m.date.formatted(date: .abbreviated, time: .shortened))
                } actions: {
                    EmptyView()
                }
            }
        }
    }
}

/// Messages fade in quickly one after another when a conversation opens, newest first.
private struct Reveal: ViewModifier {
    let order: Int
    let on: Bool

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 6)
            .animation(order < 24 ? .easeOut(duration: 0.2).delay(Double(order) * 0.018) : nil, value: on)
    }
}

/// "Claude is replying…" in the text bar: the provider's logo, its name and animated dots.
private struct AIStatusLine: View {
    let provider: AIProvider
    let verb: String

    var body: some View {
        HStack(spacing: 6) {
            if let logo = Brand.providerLogo(provider) {
                Image(nsImage: logo).renderingMode(.template).foregroundStyle(Brand.providerColor(provider))
            }
            Text("\(provider == .claudeCode ? "Claude" : "OpenRouter") is \(verb)").foregroundStyle(.secondary)
            TypingDots(color: .secondary, size: 4)
        }
        .allowsHitTesting(false)
    }
}

/// Three dots pulsing in turn, like the typing indicator in Messages.
struct TypingDots: View {
    var color: Color = .secondary
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.6) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin((t * 2 * .pi / 1.2) - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .opacity(0.35 + 0.65 * phase)
                        .scaleEffect(0.8 + 0.25 * phase)
                }
            }
        }
    }
}

/// Your side of the thread while the AI writes: a typing bubble.
private struct TypingBubble: View {
    var body: some View {
        TypingDots(color: .white.opacity(0.9), size: 7)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(red: 0.04, green: 0.5, blue: 1.0).opacity(0.85), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .help("\(AppState.shared.providerName) is writing a reply")
    }
}

/// Status line under a text that hasn't reached chat.db yet: countdown with Undo, then Sending… / Sent / Not Delivered.
struct PendingStatus: View {
    let item: OutgoingMessage
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if item.origin != .you {
                Label("AI", systemImage: "sparkles")
            }
            switch item.phase {
            case .queued:
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text("Sending in \(max(1, Int(item.sendAt.timeIntervalSinceNow.rounded(.up))))s")
                        .monospacedDigit()
                }
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
            case .sending:
                Text("Sending…")
            case .sent:
                Text(item.asTextMessage ? "Sent as Text Message" : "Sent")
            case .failed:
                Text("Not Delivered").foregroundStyle(.red)
            }
        }
    }
}

/// One text, iMessage style. Failed texts get the red "!" that opens the same actions as right-click.
struct Bubble<Footer: View, Actions: View>: View {
    let text: String
    let fromMe: Bool
    var green = false
    var faded = false
    var sender: String? = nil
    var failed = false
    var tooltip: String? = nil
    var preview: URL? = nil
    var reactions: [Reaction] = []
    var reactionNote: String = ""
    @ViewBuilder var footer: () -> Footer
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 0) {
            if fromMe { Spacer(minLength: 90) }
            VStack(alignment: fromMe ? .trailing : .leading, spacing: 3) {
                if let sender {
                    Text(sender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                HStack(spacing: 8) {
                    // Links are underlined and clickable: blue on gray, white on blue and green.
                    Text(Linkify.cached(text).attributed)
                        .tint(fromMe ? .white : Color(nsColor: .linkColor))
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(fromMe ? Color.white : Color.primary)
                        .background(fill, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .opacity(faded ? 0.55 : 1)
                        // Tapbacks sit on the bubble's top corner, like Messages: blue for yours, gray for theirs.
                        .overlay(alignment: fromMe ? .topLeading : .topTrailing) {
                            if !reactions.isEmpty {
                                HStack(spacing: -7) {
                                    ForEach(Array(reactions.enumerated()), id: \.offset) { _, r in ReactionBadge(reaction: r) }
                                }
                                .offset(x: fromMe ? -12 : 12, y: -14)
                                .help(reactionNote)
                            }
                        }
                        .padding(.top, reactions.isEmpty ? 0 : 12)
                        .contextMenu { actions() }
                        .help(tooltip ?? "")
                    if failed {
                        Menu {
                            actions()
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .red)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Not Delivered")
                    }
                }
                if let preview {
                    LinkPreviewCard(url: preview, fromMe: fromMe)
                }
                footer()
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: 560, alignment: fromMe ? .trailing : .leading)
            if !fromMe { Spacer(minLength: 90) }
        }
    }

    private var fill: Color {
        guard fromMe else { return Color.primary.opacity(0.09) }
        return green ? Color(red: 0.2, green: 0.78, blue: 0.35) : Color(red: 0.04, green: 0.5, blue: 1.0)
    }
}

struct Avatar: View {
    let title: String
    var isGroup = false
    var active = false
    var size: CGFloat = 34
    var handle: String? = nil       // contact photo from Contacts
    var photoPath: String? = nil    // group photo from Messages
    var members: [String] = []      // group members, shown as a cluster when there's no group photo
    var glass = true                // soft glass edge and float shadow; off for faces inside a group bubble
    @State private var photo: NSImage?

    var body: some View {
        let image = photo ?? AvatarPhotos.cached(handle ?? photoPath)
        Group {
            if isGroup, image == nil, members.count >= 2 {
                // Members float inside one bubble, like Messages. Real glass only on big (pinned) avatars:
                // each glass layer samples what's behind it, which adds up across a scrolling list.
                if size >= 50 {
                    MemberCluster(members: members, size: size).liquidGlass(in: Circle())
                } else {
                    MemberCluster(members: members, size: size)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .overlay { GlassEdge(size: size) }
                }
            } else {
                face(image, size: size)
                    .overlay { if glass { GlassEdge(size: size) } }
            }
        }
        // A float shadow is an extra render pass per avatar, so only pinned and header-sized ones get it.
        .shadow(color: .black.opacity(glass && size >= 50 ? 0.2 : 0), radius: size * 0.07, y: size * 0.035)
        .overlay(alignment: .bottomTrailing) {
            if active {
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(.green))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
        .task(id: "\(handle ?? photoPath ?? "")#\(AppState.shared.contactsRevision)") {
            photo = await AvatarPhotos.load(handle: handle, path: photoPath)
        }
    }

    private func face(_ image: NSImage?, size: CGFloat) -> some View {
        Circle()
            .fill(LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFill()
                        .clipShape(Circle())
                } else if isGroup || initials.isEmpty {
                    Image(systemName: isGroup ? "person.2.fill" : "person.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
    }

    private var initials: String {
        guard let first = title.first, first.isLetter else { return "" }
        return title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// No photo: Messages' gray with white initials. Any color comes from a real photo set in Contacts.
    private var palette: [Color] {
        [Color(red: 0.64, green: 0.67, blue: 0.73), Color(red: 0.51, green: 0.54, blue: 0.60)]
    }

}

/// The "i" panel: who this is, auto-reply, instructions for the AI, and where the chat is filed.
private struct ChatDetails: View {
    @Environment(AppState.self) private var state
    let chat: ChatSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 6) {
                Avatar(title: chat.title, isGroup: chat.isGroup, size: 64, handle: chat.photoHandle, photoPath: chat.photoPath,
                       members: chat.participants)
                Text(chat.title).font(.title3.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text(chat.isGroup ? "Group · \(chat.participants.count + 1) people · \(chat.service)" : "\(ContactsIndex.pretty(chat.id)) · \(chat.service)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)

            Toggle(isOn: state.enabledBinding(chat.id)) {
                Text("Auto-reply")
                Text("Let the AI answer this conversation for you")
            }
            .toggleStyle(.switch)

            Editor(title: "Instructions for the AI", text: state.instructionsBinding(chat.id),
                   placeholder: "e.g. “My sister. Keep it playful. Check my calendar before confirming plans.”")

            Field("Show in") {
                Picker("Show in", selection: Binding(get: { chat.kind }, set: { state.setKind($0, for: chat.id) })) {
                    Text("Messages").tag(ChatKind.person)
                    Text("Transactions").tag(ChatKind.transaction)
                    Text("Promotions").tag(ChatKind.promotion)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if chat.isGroup {
                Divider()
                MemberList(handles: chat.participants)
            } else if let url = URL(string: (chat.id.contains("@") ? "imessage:" : "sms:") + chat.id) {
                Button("Open in Messages") { NSWorkspace.shared.open(url) }
                    .glassButtonStyle()
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// Apple-style edge on an avatar: a soft specular highlight on top fading to a faint shade, never a hard outline.
private struct GlassEdge: View {
    let size: CGFloat

    var body: some View {
        let width = max(1, size * 0.035)
        ZStack {
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.12), .clear, .white.opacity(0.08)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: width)
                .blendMode(.plusLighter)
            Circle()
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Up to three members' faces floating in the group's glass bubble, plus "+N" for the rest.
private struct MemberCluster: View {
    @Environment(AppState.self) private var state
    let members: [String]
    let size: CGFloat

    /// (diameter, x, y) as fractions of the bubble, biggest face first.
    private var slots: [(CGFloat, CGFloat, CGFloat)] {
        members.count == 2
            ? [(0.54, -0.12, -0.10), (0.40, 0.20, 0.20)]
            : [(0.46, -0.14, -0.13), (0.36, 0.21, -0.12), (0.34, 0.04, 0.24)]
    }

    var body: some View {
        let shown = Array(zip(members.prefix(slots.count), slots))
        ZStack {
            ForEach(Array(shown.enumerated()).reversed(), id: \.offset) { _, pair in
                let (handle, slot) = pair
                Avatar(title: state.name(for: handle), size: size * slot.0, handle: handle, glass: false)
                    .shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.015)
                    .offset(x: size * slot.1, y: size * slot.2)
            }
            if members.count > 3 {
                Text("+\(members.count - 3)")
                    .font(.system(size: max(7, size * 0.16), weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .offset(x: -size * 0.24, y: size * 0.24)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Everyone in a group chat.
private struct MemberList: View {
    @Environment(AppState.self) private var state
    let handles: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(handles.count + 1) people, including you")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(handles, id: \.self) { handle in
                        HStack(spacing: 10) {
                            Avatar(title: state.name(for: handle), size: 30, handle: handle)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(state.name(for: handle)).font(.callout.weight(.medium)).lineLimit(1)
                                if state.contacts.name(for: handle) != nil {
                                    Text(ContactsIndex.pretty(handle)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .contextMenu {
                            Button("Copy \(handle.contains("@") ? "Email" : "Number")") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(handle, forType: .string)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 280)
    }
}

/// Contact and group photos: memory first, then a disk cache of finished avatars, and only then the slow path
/// (Contacts fetch, decode, face framing), all off the main thread. Concurrent requests for one photo share the work.
@MainActor
enum AvatarPhotos {
    private static var images: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    private static var inflight: [String: Task<NSImage?, Never>] = [:]

    static func cached(_ key: String?) -> NSImage? {
        key.flatMap { images[$0] }
    }

    /// Contacts changed or finished loading: photos that weren't found before may be there now.
    static func reset() {
        images = [:]
        missing = []
    }

    /// Contacts changed: rebuild avatars from scratch on next use.
    nonisolated static func clearDiskCache() {
        try? FileManager.default.removeItem(at: diskDirectory)
    }

    /// Warm the photos the list is about to show.
    static func prefetch(_ chats: [ChatSummary]) {
        for chat in chats {
            if let handle = chat.photoHandle { Task { _ = await load(handle: handle, path: nil) } }
            if let path = chat.photoPath { Task { _ = await load(handle: nil, path: path) } }
            for member in chat.participants.prefix(3) where chat.isGroup && chat.photoPath == nil {
                Task { _ = await load(handle: member, path: nil) }
            }
        }
    }

    static func load(handle: String?, path: String?) async -> NSImage? {
        guard let key = handle ?? path else { return nil }
        if let hit = images[key] { return hit }
        guard !missing.contains(key) else { return nil }
        if let running = inflight[key] { return await running.value }
        let contacts = AppState.shared.contacts
        let task = Task<NSImage?, Never> {
            let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let file = diskURL(for: key)
                if let data = try? Data(contentsOf: file), let cached = decode(data, maxPixels: 360) { return cached }
                let made = render(handle: handle, path: path, contacts: contacts)
                if let made { writeJPEG(made, to: file) }
                return made
            }.value
            return cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { images[key] = image } else { missing.insert(key) }
        return image
    }

    // MARK: Disk cache (~/Library/Caches/com.lithometric.imessager/avatars)

    nonisolated private static var diskDirectory: URL {
        ContactsIndex.cacheDirectory.appendingPathComponent("avatars", isDirectory: true)
    }

    nonisolated private static func diskURL(for key: String) -> URL {
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return diskDirectory.appendingPathComponent(String(hash, radix: 36) + ".jpg")
    }

    nonisolated private static func writeJPEG(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// The slow path: Contacts crop when sharp enough, else the full photo framed on the face.
    nonisolated private static func render(handle: String?, path: String?, contacts: ContactsIndex) -> CGImage? {
        if let handle {
            guard let photo = contacts.photo(for: handle) else { return nil }
            if let cropped = photo.cropped.flatMap({ decode($0, maxPixels: 360) }), max(cropped.width, cropped.height) >= 160 {
                return square(cropped)
            }
            if let original = photo.original.flatMap({ decode($0, maxPixels: 1400) }) {
                return decodeSquare(faceCentered(original))
            }
            return photo.cropped.flatMap { decode($0, maxPixels: 360) }.map(square)
        }
        guard let data = path.flatMap({ FileManager.default.contents(atPath: $0) }),
              let image = decode(data, maxPixels: 1400) else { return nil }
        return decodeSquare(faceCentered(image))
    }
}

// MARK: - Photo framing

/// Decodes and downsamples once, applying EXIF orientation.
private func decode(_ data: Data, maxPixels: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxPixels]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// Center square crop.
private func square(_ image: CGImage) -> CGImage {
    let side = min(image.width, image.height)
    let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
    return image.cropping(to: rect) ?? image
}

/// A square around the largest face (head and shoulders), or the center if there's no face.
private func faceCentered(_ image: CGImage) -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let request = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cgImage: image).perform([request])
    guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return square(image) }
    let box = face.boundingBox // normalized, origin bottom-left
    let side = min(min(w, h), max(box.width * w, box.height * h) * 2.4)
    var x = box.midX * w - side / 2
    var y = (1 - box.midY) * h - side / 2 - side * 0.04 // a touch of headroom
    x = min(max(0, x), w - side)
    y = min(max(0, y), h - side)
    return image.cropping(to: CGRect(x: x, y: y, width: side, height: side).integral) ?? square(image)
}

/// Downsample a cropped square to avatar size.
private func decodeSquare(_ image: CGImage) -> CGImage {
    guard image.width > 360, let ctx = CGContext(data: nil, width: 360, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 360, height: 360))
    return ctx.makeImage() ?? image
}

private extension View {
    /// Keep the newest message in view while photos and link previews load and grow the transcript.
    @ViewBuilder
    func staysAtBottom() -> some View {
        if #available(macOS 15, *) { defaultScrollAnchor(.bottom, for: .sizeChanges) } else { self }
    }

    /// Small glass capsule floating above the composer.
    func toast() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .liquidGlass(in: Capsule())
    }
}

enum Fmt {
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// "Read 9:41 PM", "Read Yesterday", "Read 10/28/26", like Messages.
    static func receipt(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
