import AppKit
import EventKit
import SwiftUI

enum ActivityKind: String, Sendable {
    case received, sent, greeted, draft, skipped, error, info
}

struct ActivityEvent: Identifiable, Sendable {
    let id = UUID()
    let date = Date()
    let kind: ActivityKind
    let chat: String?
    let title: String?
    let text: String
    let ms: Int?
    let detail: String?
}

struct ChatSummary: Identifiable, Hashable, Sendable {
    let id: String          // chat_identifier
    let guid: String        // newest chat row, used for sending
    let title: String
    let isGroup: Bool
    let isKnown: Bool
    let service: String
    let preview: String
    let lastFromMe: Bool
    let lastFailed: Bool
    let lastDate: Date
    var unread = 0
    var kind = ChatKind.person
    var pin: Int?               // position in Messages' pinned conversations
    var photoPath: String?      // group photo
    var participants: [String] = []
    var lastSender: String?

    var isPinned: Bool { pin != nil }
    var photoHandle: String? { isGroup ? nil : id }
}

@MainActor @Observable
final class AppState {
    static let shared = AppState()
    private static let keyAccount = "openrouter"

    var config: AppConfig { didSet { configDidChange(from: oldValue) } }
    var apiKey: String { didSet { if apiKey != oldValue { Keychain.set(apiKey.trimmed, for: Self.keyAccount) } } }
    var chats: [ChatSummary] = []
    var activity: [ActivityEvent] = []
    var dbAccess: DBAccess = .checking
    var contactsStatus = ContactsIndex.status
    var automation: OSStatus?
    var lastHealthCheck: Date?
    /// The page open as a modal over the app (Settings, Activity, Integrations, Setup).
    var modal: AppModal?
    /// The New Message screen is showing (compose button or ⌘N).
    var composing = false
    /// AI one-liners for conversations with unread texts, keyed by chat id.
    var summaries: [String: String] = [:]
    /// A conversation to open (from a notification click).
    var openRequest: String?
    /// The conversation on screen, so its new texts don't pop up a banner (like Messages).
    var viewingChat: String?
    /// Whether macOS allows iMessager's notifications (checked at launch and when Settings opens).
    var notificationsAllowed: Bool?
    /// Conversations the AI is writing a reply in right now, so the text bar can show it and lock.
    var replying: [String: UUID] = [:]
    @ObservationIgnored private var summarized: [String: Date] = [:]
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    /// True once the conversation list has loaded at least once, so the list can show a skeleton until then.
    var chatsLoaded = false

    var showChecklist: Bool {
        get { modal == .setup }
        set { modal = newValue ? .setup : (modal == .setup ? nil : modal) }
    }
    var transientNotices: [AppNotice] = []
    var dismissedNotices: Set<String> = []
    var integrationStatus: [UUID: String] = [:]
    var models: [ORModel] = []
    var sentCount = 0
    var lastLatency: Int?
    var outbox: [OutgoingMessage] = []
    /// OpenRouter key usage and limit (USD), refreshed when Home opens.
    var credits: (usage: Double, limit: Double?, monthly: Double?)?
    /// Bumped when Contacts finishes loading, so avatars that rendered too early fetch their photos again.
    var contactsRevision = 0
    /// Bumped whenever chat.db changes (new texts, delivery and read receipts) so open views re-read it.
    var revision = 0

    @ObservationIgnored let db = ChatDB()
    @ObservationIgnored let contacts = ContactsIndex()
    @ObservationIgnored let llm: OpenRouterClient
    @ObservationIgnored let sender = MessageSender()
    @ObservationIgnored let hub: IntegrationHub
    @ObservationIgnored let claude = ClaudeCode()
    /// Claude Code: installed, signed in, on a Claude plan? Checked when that provider is picked.
    var claudeStatus: ClaudeCode.Status?
    @ObservationIgnored private(set) var agent: Agent?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var booted = false
    @ObservationIgnored var healthTask: Task<Void, Never>?
    @ObservationIgnored var outboxTimers: [UUID: Task<Void, Never>] = [:]

    var hasDiskAccess: Bool { dbAccess == .ok }
    var contactsAccess: Bool { contactsStatus == .authorized }

    private init() {
        config = ConfigStore.load()
        apiKey = Keychain.get(Self.keyAccount) ?? ""
        let llm = OpenRouterClient()
        self.llm = llm
        hub = IntegrationHub(
            llm: llm,
            credentials: { await AppState.shared.credentials() },
            report: { id, status in Task { @MainActor in AppState.shared.integrationStatus[id] = status } })
        agent = Agent(state: self, db: db, contacts: contacts, hub: hub, llm: llm, claude: claude)
    }

    // MARK: - Lifecycle

    func boot() async {
        guard !booted else { return }
        booted = true
        signal(SIGPIPE, SIG_IGN) // a dying MCP server must not take the app with it
        Task.detached(priority: .background) { Staging.sweep() }
        Notifier.shared.start()
        Task { notificationsAllowed = await Notifier.shared.allowed() }

        let contacts = self.contacts
        Task.detached(priority: .utility) {
            _ = await contacts.requestAccess()
            contacts.reload()
            await AppState.shared.contactsLoaded()
        }
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { _ in
            AvatarPhotos.clearDiskCache()
            Task.detached(priority: .utility) {
                contacts.reload()
                await AppState.shared.refreshChats()
            }
        }

        applyAppearance()
        await hub.sync(config.integrations)
        if !apiKey.isEmpty { Task { await llm.warm(key: apiKey) } }
        if config.provider == .claudeCode { Task { await refreshClaudeStatus() } }
        Task { await loadModels() }

        // Re-check the moment you come back from System Settings, plus a steady background loop.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppState.shared.checkHealth() }
        }
        await checkHealth(initial: true)
        startHealthLoop()
    }

    func startAgent() async {
        await agent?.start()
        await refreshChats()
    }

    func saveNow() {
        saveTask?.cancel()
        ConfigStore.save(config)
    }

    private func contactsLoaded() async {
        contactsStatus = ContactsIndex.status
        AvatarPhotos.reset()
        contactsRevision &+= 1
        await refreshChats()
    }

    private func configDidChange(from old: AppConfig) {
        if old.provider != config.provider || old.claudeCodePath != config.claudeCodePath, config.provider == .claudeCode {
            Task { await refreshClaudeStatus() }
        }
        if old.appearance != config.appearance { applyAppearance() }
        if old.chatKinds != config.chatKinds { chatsDidChange() }
        saveTask?.cancel()
        let snapshot = config
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            ConfigStore.save(snapshot)
        }
        if old.integrations != config.integrations {
            syncTask?.cancel()
            let integrations = config.integrations
            syncTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                await hub.sync(integrations)
            }
        }
    }

    fileprivate func credentials() -> (key: String, model: String) { (apiKey, config.model) }

    // MARK: - Chats

    /// Automatic follows macOS; Light and Dark override it for this app only.
    func applyAppearance() {
        switch config.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func refreshChats() async {
        guard hasDiskAccess, var raw = try? await db.recentChats(limit: 250) else { return }
        let unreadDates = (try? await db.unreadDates()) ?? [:]
        let unread = unreadDates.reduce(into: [String: Int]()) { counts, entry in
            let seen = config.readThrough[entry.key] ?? .distantPast
            counts[entry.key] = entry.value.filter { $0 > seen }.count
        }.merging(config.markedUnread.map { ($0, 1) }) { max($0, $1) }
        let pins = Pins.load()
        // Pinned chats stay on top even when they're older than the recent list.
        let unmatched = pins.filter { pin in !raw.contains { Pins.order(of: ($0.identifier, $0.guid, $0.groupID), in: [pin]) != nil } }
        if !unmatched.isEmpty, let older = try? await db.recentChats(limit: unmatched.count, only: unmatched) {
            let known = Set(raw.map(\.identifier))
            raw += older.filter { !known.contains($0.identifier) }
        }
        // Naming, sorting into Messages/Transactions/Promotions and pin matching run off the main thread.
        let input = raw
        let (contacts, overrides) = (self.contacts, config.chatKinds)
        chats = await Task.detached(priority: .userInitiated) {
            Self.summaries(input, unread: unread, pins: pins, overrides: overrides, contacts: contacts)
        }.value
        AvatarPhotos.prefetch(chats.filter(\.isPinned) + chats.prefix(40))
        summarizeUnread()
        updateDockBadge()
        revision &+= 1
        chatsLoaded = true
    }

    /// Coalesces bursts of new messages into one list refresh.
    func chatsDidChange() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshChats()
        }
    }

    nonisolated private static func summaries(_ raw: [RawChat], unread: [String: Int], pins: [String],
                                              overrides: [String: ChatKind], contacts: ContactsIndex) -> [ChatSummary] {
        raw.map { r in
            let known = r.isGroup || contacts.name(for: r.identifier) != nil
            let title: String
            if let name = r.displayName, !name.isEmpty {
                title = name
            } else if r.isGroup {
                title = groupTitle(r.participants.map { contacts.name(for: $0)?.split(separator: " ").first.map(String.init)
                    ?? ContactsIndex.pretty($0) })
            } else {
                title = contacts.name(for: r.identifier) ?? ContactsIndex.pretty(r.identifier)
            }
            var chat = ChatSummary(id: r.identifier, guid: r.guid, title: title, isGroup: r.isGroup, isKnown: known,
                                   service: r.service, preview: r.preview, lastFromMe: r.lastFromMe, lastFailed: r.lastFailed,
                                   lastDate: r.lastDate)
            chat.unread = unread[r.identifier] ?? 0
            chat.kind = overrides[r.identifier]
                ?? Classifier.classify(handle: r.identifier, texts: r.samples, known: known, isGroup: r.isGroup)
            chat.pin = Pins.order(of: (r.identifier, r.guid, r.groupID), in: pins)
            chat.photoPath = r.photoPath
            chat.participants = r.participants
            chat.lastSender = r.lastSender
            return chat
        }
    }

    /// How Messages names a group without a name: "Beshoy & Jonah", "A, B & C", "A, B & 3 others".
    nonisolated static func groupTitle(_ names: [String]) -> String {
        switch names.count {
        case 0: "Group"
        case 1: names[0]
        case 2: "\(names[0]) & \(names[1])"
        case 3: "\(names[0]), \(names[1]) & \(names[2])"
        default: "\(names[0]), \(names[1]) & \(names.count - 2) others"
        }
    }

    func name(for handle: String) -> String {
        contacts.name(for: handle) ?? ContactsIndex.pretty(handle)
    }

    func title(for key: String) -> String {
        chats.first(where: { $0.id == key })?.title ?? contacts.name(for: key) ?? ContactsIndex.pretty(key)
    }

    func history(_ key: String, limit: Int = 60) async -> [ChatMessage] {
        (try? await db.history(identifier: key, limit: limit)) ?? []
    }

    // MARK: - Per-contact switches (default off)

    var enabledCount: Int { config.contacts.values.filter(\.enabled).count }

    func beginReplying(_ chat: String) -> UUID {
        let token = UUID()
        replying[chat] = token
        return token
    }

    func endReplying(_ chat: String, _ token: UUID) {
        if replying[chat] == token { replying[chat] = nil }
    }

    /// Stop: drop the AI reply being written so you can answer yourself (the AI steps back like it does when you reply).
    func stopReplying(_ chat: String) async {
        replying[chat] = nil
        await agent?.userIsReplying(chat)
    }

    var providerName: String { config.provider == .claudeCode ? "Claude" : "OpenRouter" }

    /// You've seen this conversation in iMessager (Messages itself can't be told; see `readThrough`).
    func markRead(_ id: String, through date: Date? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        let through = date ?? chats[i].lastDate
        if chats[i].unread > 0 || config.markedUnread.contains(id) || (config.readThrough[id] ?? .distantPast) < through {
            config.readThrough[id] = through
            config.markedUnread.remove(id)
            if config.readThrough.count > 600 {
                let oldest = config.readThrough.sorted { $0.value < $1.value }.prefix(100).map(\.key)
                oldest.forEach { config.readThrough[$0] = nil }
            }
        }
        if chats[i].unread != 0 { chats[i].unread = 0 }
        updateDockBadge()
    }

    /// Red Dock badge with your unread count, like Messages.
    func updateDockBadge() {
        let count = unreadCount
        NSApp.dockTile.badgeLabel = count > 0 ? (count > 999 ? "999+" : "\(count)") : nil
    }

    /// A new text (or tapback) arrived: notify like Messages, unless the chat is muted in Messages, filtered out
    /// of the main list (transactions, promotions), or you turned these off.
    func notifyIncoming(_ m: ChatMessage) async {
        guard config.notifications.incoming, !m.isFromMe, let key = m.chatIdentifier else { return }
        let known = chats.first { $0.id == key }
        if let known, !inMainList(known) { return }
        if known == nil, !m.isGroup,
           Classifier.classify(handle: key, texts: [m.text], known: contacts.name(for: key) != nil, isGroup: false) != .person,
           config.hideAutomated { return }
        let muted = Muted.load()
        if muted.contains(where: { $0 == key || $0 == m.chatGUID || $0.hasSuffix(";" + key) }) { return }

        let sender = m.sender.map { name(for: $0) } ?? title(for: key)
        let group = m.isGroup ? title(for: key) : nil
        let body: String
        if !config.notifications.previews {
            body = m.hasAttachments ? "Attachment" : "iMessage"
        } else if m.hasAttachments && m.caption.isEmpty {
            body = "Attachment"
        } else {
            body = m.caption
        }
        let photo = await AvatarPhotos.load(handle: m.sender ?? key, path: nil)
        Notifier.shared.postMessage(title: sender, subtitle: group, body: body, chat: key, photo: photo)
    }

    func markUnread(_ id: String) {
        config.markedUnread.insert(id)
        if let i = chats.firstIndex(where: { $0.id == id }), chats[i].unread == 0 { chats[i].unread = 1 }
        updateDockBadge()
    }

    /// Whether a chat shows in the main Messages list.
    func inMainList(_ chat: ChatSummary) -> Bool { !config.hideAutomated || chat.kind == .person }

    /// Unread texts in the main list, for the sidebar badge.
    var unreadCount: Int { chats.filter(inMainList).reduce(0) { $0 + $1.unread } }

    /// Moves a conversation between Messages, Transactions and Promotions. Nil goes back to automatic.
    func setKind(_ kind: ChatKind?, for chat: String) {
        config.chatKinds[chat] = kind
    }

    func isEnabled(_ key: String) -> Bool { config.contacts[key]?.enabled ?? false }

    func setEnabled(_ key: String, _ on: Bool) {
        var settings = config.contacts[key] ?? ContactSettings()
        settings.enabled = on
        config.contacts[key] = (!on && settings.instructions.isEmpty) ? nil : settings
    }

    func enabledBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.isEnabled(key) }, set: { self.setEnabled(key, $0) })
    }

    func instructionsBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { self.config.contacts[key]?.instructions ?? "" },
            set: { text in
                var settings = self.config.contacts[key] ?? ContactSettings()
                settings.instructions = text
                self.config.contacts[key] = (!settings.enabled && text.isEmpty) ? nil : settings
            })
    }

    // MARK: - Actions

    func preview(_ key: String) async throws -> Draft {
        guard let agent else { throw AppError("Agent isn't ready") }
        return try await agent.preview(key: key)
    }

    /// Summaries for conversations with several unread texts (or one long one), newest first, one at a time in the
    /// background. Each is kept until that conversation gets a newer message.
    private func summarizeUnread() {
        guard config.summarizeUnread, aiReady, summaryTask == nil else { return }
        let wanted = chats.filter { inMainList($0) && $0.unread > 0 && ($0.unread >= 2 || $0.preview.count > 160) }
            .filter { summarized[$0.id] != $0.lastDate }
            .prefix(12)
        guard !wanted.isEmpty else { return }
        let jobs = wanted.map { ($0.id, $0.title, $0.unread, $0.lastDate) }
        summaryTask = Task {
            defer { summaryTask = nil }
            for (id, title, unread, date) in jobs {
                guard !Task.isCancelled, let agent else { return }
                summarized[id] = date
                let texts = (try? await db.history(identifier: id, limit: min(unread, 25) + 5))?
                    .filter { !$0.isFromMe && !$0.isRetracted }.suffix(min(unread, 25)).map(\.text) ?? []
                if let line = try? await agent.summarize(title: title, texts: Array(texts)) { summaries[id] = line }
            }
        }
    }

    /// An existing 1:1 conversation with this number or email, even one older than the recent list.
    func existingChat(with handle: String) async -> ChatSummary? {
        if let hit = chats.first(where: { !$0.isGroup && ContactsIndex.sameHandle($0.id, handle) }) { return hit }
        let key = ContactsIndex.normalized(handle)
        guard let raw = try? await db.recentChats(limit: 1, only: [key, handle]), let first = raw.first, !first.isGroup else { return nil }
        let summary = Self.summaries([first], unread: [:], pins: [], overrides: config.chatKinds, contacts: contacts)[0]
        if !chats.contains(where: { $0.id == summary.id }) { chats.append(summary) }
        return summary
    }

    /// First text to someone new. Messages starts the conversation; it shows up in the list a moment later.
    func startConversation(with handle: String, text: String) -> String {
        let key = ContactsIndex.normalized(handle)
        enqueue(text, chat: key, guid: "", handle: key, origin: .you)
        return key
    }

    /// A text you typed. It waits out the undo window, and the agent steps back from this chat like it does when you reply from your phone.
    func send(_ text: String, to chat: ChatSummary, attachments: [URL] = [], asTextMessage: Bool = false) async {
        await agent?.userIsReplying(chat.id)
        let handle = chat.isGroup ? nil : chat.id
        // Photos and files first, each as its own message, then the text, like Messages.
        for file in attachments {
            enqueue("", chat: chat.id, guid: chat.guid, handle: handle, origin: .you, attachment: file, asTextMessage: asTextMessage)
        }
        if !text.isEmpty {
            enqueue(text, chat: chat.id, guid: chat.guid, handle: handle, origin: .you, asTextMessage: asTextMessage)
        }
    }

    func log(_ kind: ActivityKind, _ chat: String?, _ text: String, ms: Int? = nil, detail: String? = nil) {
        if kind == .error { config.stats.errors += 1 }
        if kind == .draft, config.notifications.drafts {
            Notifier.shared.post(title: chat.map(title(for:)) ?? "iMessager", subtitle: "AI draft (dry run, not sent)", body: text, chat: chat)
        }
        activity.insert(ActivityEvent(kind: kind, chat: chat, title: chat.map(title(for:)), text: text, ms: ms, detail: detail), at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
        if kind == .sent || kind == .greeted {
            sentCount += 1
            if let ms { lastLatency = ms }
        }
    }

    /// Adds one OpenRouter call's tokens and cost (USD) to the running totals.
    func recordUsage(_ usage: JSON?) {
        guard let usage else { return }
        config.stats.calls += 1
        config.stats.promptTokens += usage["prompt_tokens"]?.int ?? 0
        config.stats.completionTokens += usage["completion_tokens"]?.int ?? 0
        config.stats.costUSD += usage["cost"]?.number ?? 0
    }

    /// Whether replies can be written with the chosen provider.
    var aiReady: Bool {
        switch config.provider {
        case .openRouter: !apiKey.trimmed.isEmpty
        case .claudeCode: claudeStatus?.ready ?? false
        }
    }

    func refreshClaudeStatus() async {
        claudeStatus = await claude.status(customPath: config.claudeCodePath)
    }

    /// Tokens from a Claude Code reply. No dollars: it's included in the Claude plan.
    func recordClaudeUsage(_ reply: ClaudeCode.Reply) {
        config.stats.calls += 1
        config.stats.promptTokens += reply.inputTokens
        config.stats.completionTokens += reply.outputTokens
    }

    func refreshCredits() async {
        guard !apiKey.trimmed.isEmpty, let info = try? await llm.keyInfo(key: apiKey.trimmed) else { return }
        credits = (info["usage"]?.number ?? 0, info["limit"]?.number, info["usage_monthly"]?.number)
    }

    func verifyKey() async -> String {
        guard !apiKey.trimmed.isEmpty else { return "Paste a key first" }
        do {
            let info = try await llm.keyInfo(key: apiKey.trimmed)
            var text = String(format: "Key works · $%.2f used", info["usage"]?.number ?? 0)
            if let limit = info["limit"]?.number { text += String(format: " of $%.2f", limit) }
            return text
        } catch {
            return error.localizedDescription
        }
    }

    func loadModels() async {
        if let list = try? await llm.models(), !list.isEmpty { models = list }
    }

    // MARK: - Integrations

    func addIntegration(_ kind: IntegrationKind) {
        config.integrations.append(.new(kind))
    }

    func removeIntegration(_ id: UUID) {
        config.integrations.removeAll { $0.id == id }
    }

    func describeIntegration(_ id: UUID) async -> String {
        syncTask?.cancel()
        await hub.sync(config.integrations)
        return await hub.describe(id)
    }

    func restartIntegration(_ id: UUID) async {
        await hub.restart(id)
    }

    // MARK: - Permissions

    func requestCalendarAccess() async {
        _ = try? await EKEventStore().requestFullAccessToEvents()
    }

    func requestContactsAccess() async {
        _ = await contacts.requestAccess()
        let contacts = self.contacts
        await Task.detached { contacts.reload() }.value
        await contactsLoaded()
    }

    func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func relaunch() {
        saveNow()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    var statusLine: String {
        if !hasDiskAccess { return "Needs Full Disk Access" }
        let on = enabledCount
        return "\(config.dryRun ? "Dry run" : "Listening") · \(on) contact\(on == 1 ? "" : "s") on · \(sentCount) sent"
    }
}
