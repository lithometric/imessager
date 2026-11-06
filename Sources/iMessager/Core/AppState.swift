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
    var hasMine = false

    var isPinned: Bool { pin != nil }
    var photoHandle: String? { isGroup ? nil : id }
}

@MainActor @Observable
final class AppState {
    static let shared = AppState()
    private static let keyAccount = "openrouter"

    var config: AppConfig { didSet { configDidChange(from: oldValue) } }
    var apiKey: String { didSet { if apiKey != oldValue { Keychain.set(apiKey.trimmed, for: Self.keyAccount) } } }
    var chats: [ChatSummary] = [] { didSet { chatIndex = Dictionary(chats.enumerated().map { ($1.id, $0) }) { a, _ in a } } }
    @ObservationIgnored private var chatIndex: [String: Int] = [:]
    var activity: [ActivityEvent] = []
    var dbAccess: DBAccess = .checking
    var contactsStatus = ContactsIndex.status
    var automation: OSStatus?
    var lastHealthCheck: Date?
    /// The page open as a modal over the app (Settings, Activity, Integrations, Setup).
    var modal: AppModal?
    /// The New Message screen is showing (compose button or ⌘N).
    var composing = false
    /// What the search bar is doing with a question or request you typed, and what it came back with.
    var command: CommandRun?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    /// AI one-liners for conversations with unread texts, keyed by chat id.
    var summaries: [String: String] = [:]
    /// A conversation to open (from a notification click).
    var openRequest: String?
    /// The conversation on screen, so its new texts don't pop up a banner (like Messages).
    var viewingChat: String?
    /// Whether macOS allows iMessager's notifications (checked at launch and when Settings opens).
    var notificationsAllowed: Bool?
    /// Chats where the AI is holding off because you texted them yourself, and until when.
    var holds: [String: Date] = [:]
    /// Conversations the AI is writing a reply in right now, so the text bar can show it and lock.
    var replying: [String: UUID] = [:]
    @ObservationIgnored private var summarized: [String: Date] = [:]
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    /// The daily recap is being written.
    var makingRecap = false
    /// Conversations to open with a follow-up written for a checked-off to-do: chat id → the to-do.
    var todoDrafts: [String: String] = [:]
    /// To-dos whose follow-up is being written to send in the background.
    var followingUp: Set<UUID> = []
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
        Wakefulness.stayResponsive()
        Notifier.shared.start()
        Notifier.shared.registerActions(aiName: config.provider == .claudeCode ? "Claude" : "AI")
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
        if old.provider != config.provider {
            Notifier.shared.registerActions(aiName: config.provider == .claudeCode ? "Claude" : "AI")
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
        // Messages' pins until you change them here; after that, yours (Messages has no way for apps to change its pins).
        let pins = config.pins ?? Pins.load()
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
        prefetchThreads()
        summarizeUnread()
        recapIfDue()
        unsubscribeNew()
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
            chat.hasMine = r.hasMine
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
        let messages = (try? await db.history(identifier: key, limit: limit)) ?? []
        remember(messages, for: key)
        return messages
    }

    // MARK: - Thread cache (opening a conversation shows it at once, then refreshes quietly)

    @ObservationIgnored private var threads: [String: [ChatMessage]] = [:]
    @ObservationIgnored private var threadOrder: [String] = []

    func cachedThread(_ key: String) -> [ChatMessage]? { threads[key] }

    /// The pointer is on a conversation: load it now, so it's ready by the time you click.
    func warmThread(_ key: String) {
        guard threads[key] == nil, warming.insert(key).inserted else { return }
        Task(priority: .userInitiated) {
            _ = await history(key, limit: 80)
            warming.remove(key)
        }
    }

    @ObservationIgnored private var warming: Set<String> = []

    private func remember(_ messages: [ChatMessage], for key: String) {
        threads[key] = messages
        // Links sent on their own show as previews: have the saved ones ready so they open at full size.
        LinkPreviews.shared.warm(messages.compactMap { m in
            let text = m.caption.trimmed
            return text.contains(" ") || text.contains("\n") ? nil : Linkify.cached(text).url
        })
        threadOrder.removeAll { $0 == key }
        threadOrder.append(key)
        if threadOrder.count > 60 { threads[threadOrder.removeFirst()] = nil }
    }

    /// Loads the conversations you're likely to open next (pins and the newest), one at a time in the background.
    private func prefetchThreads() {
        let keys = (chats.filter(\.isPinned) + chats.prefix(24)).map(\.id).filter { threads[$0] == nil }
        guard !keys.isEmpty else { return }
        Task(priority: .utility) {
            for key in keys where threads[key] == nil { _ = await history(key, limit: 80) }
        }
    }

    // MARK: - Per-contact switches (default off)

    var enabledCount: Int {
        config.autoReplyEveryone || config.autoReplyGroups
            ? chats.filter { isEnabled($0.id) }.count : config.contacts.values.filter(\.enabled).count
    }

    /// Who the blanket switches cover. "Everyone": 1:1 conversations with real people you know (in Contacts) or have
    /// texted, not new numbers, codes, transactions or promotions. "Every group": all group chats.
    func coveredByEveryone(_ chat: ChatSummary) -> Bool {
        chat.isGroup
            ? config.autoReplyGroups && chat.kind != .promotion && chat.kind != .transaction
            : config.autoReplyEveryone && chat.kind == .person && (chat.isKnown || chat.hasMine)
    }

    /// The agent's check when a text arrives (the chat may not be in the list yet).
    func autoReplies(to key: String, isGroup: Bool) async -> Bool {
        if let s = config.contacts[key] {
            if s.enabled { return true }
            if s.disabled { return false }
        }
        if let i = chatIndex[key] { return coveredByEveryone(chats[i]) }
        if isGroup { return config.autoReplyGroups }
        guard config.autoReplyEveryone else { return false }
        if contacts.name(for: key) != nil { return true }
        return ((try? await db.sentCount(identifier: key)) ?? 0) > 0
    }

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

    // MARK: - Pins (up to 9, like Messages)

    static let maxPins = 9

    var pinnedIDs: [String] { chats.filter(\.isPinned).sorted { $0.pin! < $1.pin! }.map(\.id) }

    var canPinMore: Bool { pinnedIDs.count < Self.maxPins }

    func pin(_ id: String, at index: Int? = nil) {
        if index == nil, pinnedIDs.contains(id) { return }   // already pinned: stays where it is
        var order = pinnedIDs.filter { $0 != id }
        guard order.count < Self.maxPins else { return }
        order.insert(id, at: min(max(index ?? order.count, 0), order.count))
        setPins(order)
    }

    func unpin(_ id: String) {
        setPins(pinnedIDs.filter { $0 != id })
    }

    /// Drag-to-reorder: move a pin before another one (or pin it there if it wasn't pinned).
    func movePin(_ id: String, before target: String) {
        guard id != target else { return }
        var order = pinnedIDs.filter { $0 != id }
        guard pinnedIDs.contains(id) || order.count < Self.maxPins else { return }
        order.insert(id, at: order.firstIndex(of: target) ?? order.count)
        setPins(order)
    }

    private func setPins(_ order: [String]) {
        config.pins = order
        for i in chats.indices { chats[i].pin = order.firstIndex(of: chats[i].id) }
    }

    /// You've seen this conversation in iMessager (Messages itself can't be told; see `readThrough`).
    func markRead(_ id: String, through date: Date? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        let through = date ?? chats[i].lastDate
        if chats[i].unread > 0 || config.markedUnread.contains(id) { syncToMessages(chats[i], read: true) }
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

    /// Mirror a read/unread change into Messages, off the main thread (Accessibility calls can take a moment).
    private func syncToMessages(_ chat: ChatSummary, read: Bool) {
        guard config.syncReadWithMessages, MessagesSync.allowed else { return }
        var names = [chat.title]
        if !chat.isGroup { names += [ContactsIndex.pretty(chat.id), chat.id] }
        Task.detached(priority: .utility) { MessagesSync.mark(names: names, read: read) }
    }

    /// Opens System Settings straight to Messages' notifications (apps can't switch another app's off themselves).
    func openMessagesNotificationSettings() {
        config.seenTips.insert("messages-notifications")
        let deep = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.apple.MobileSMS")!
        NSWorkspace.shared.open(deep)
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
        Notifier.shared.postMessage(title: sender, subtitle: group, body: body, chat: key, handle: m.sender ?? key, photo: photo)
    }

    func markUnread(_ id: String) {
        if let chat = chats.first(where: { $0.id == id }) { syncToMessages(chat, read: false) }
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

    func isEnabled(_ key: String) -> Bool {
        if let s = config.contacts[key] {
            if s.enabled { return true }
            if s.disabled { return false }
        }
        guard let i = chatIndex[key] else { return false }
        return coveredByEveryone(chats[i])
    }

    func setEnabled(_ key: String, _ on: Bool) {
        var settings = config.contacts[key] ?? ContactSettings()
        let was = isEnabled(key)
        settings.enabled = on
        // With "everyone" on, switching a chat off has to be remembered, or it'd count as covered again.
        let blanket = chats.first(where: { $0.id == key }).map { $0.isGroup ? config.autoReplyGroups : config.autoReplyEveryone }
            ?? (config.autoReplyEveryone || config.autoReplyGroups)
        settings.disabled = !on && blanket
        config.contacts[key] = (!settings.enabled && !settings.disabled && settings.instructions.isEmpty) ? nil : settings
        // Turning it on means "answer now": end any hold, and reply if their latest text is waiting.
        if on, !was, let chat = chats.first(where: { $0.id == key }) {
            Task { await agent?.resume(key, guid: chat.guid, handle: chat.isGroup ? nil : chat.id, answer: true) }
        }
    }

    func setHold(_ key: String, until: Date?) {
        holds[key] = until
    }

    /// From a notification: have the AI answer this conversation now, even with auto-reply off.
    func aiReply(to chatID: String) async {
        if !chats.contains(where: { $0.id == chatID }) { await refreshChats() }
        guard let chat = chats.first(where: { $0.id == chatID }) else { return }
        markRead(chat.id)
        await agent?.replyOnRequest(chat.id, guid: chat.guid, handle: chat.isGroup ? nil : chat.id)
    }

    /// Reply Now: end the hold and answer their latest text.
    func replyNow(_ chat: ChatSummary) {
        Task { await agent?.resume(chat.id, guid: chat.guid, handle: chat.isGroup ? nil : chat.id, answer: true) }
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
            .filter { (aiBlocks[$0.id] ?? .distantPast) < .now }
            .filter { summarized[$0.id] != $0.lastDate }
            .prefix(12)
        guard !wanted.isEmpty else { return }
        let jobs = wanted.map { ($0.id, $0.title, $0.unread, $0.lastDate) }
        summaryTask = Task {
            defer { summaryTask = nil }
            for (id, title, unread, date) in jobs {
                guard !Task.isCancelled, let agent, allowAutomatic("summary", chat: id) else { return }
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

    // MARK: - Command bar

    struct CommandRun: Equatable {
        let request: String
        var step = "Thinking…"
        var running = true
        var answer = ""
        var error: String?
        var drafts: [CommandDraft] = []
        var sentCount = 0
    }

    /// A question or request typed in the search bar, done by the AI with Contacts and your messages.
    func runCommand(_ request: String) {
        commandTask?.cancel()
        command = CommandRun(request: request)
        commandTask = Task {
            let commander = Commander(state: self, onStep: { [weak self] step in
                if self?.command?.running == true { self?.command?.step = step }
            }, onDraft: { [weak self] draft in
                self?.command?.drafts.append(draft)
            })
            do {
                let answer = try await commander.run(request)
                guard !Task.isCancelled else { return }
                command?.answer = answer
                command?.running = false
            } catch {
                guard !Task.isCancelled else { return }
                command?.error = error.localizedDescription
                command?.running = false
            }
        }
    }


    func dismissCommand() {
        commandTask?.cancel()
        commandTask = nil
        command = nil
    }

    func editDraft(_ id: UUID, text: String) {
        guard let i = command?.drafts.firstIndex(where: { $0.id == id }) else { return }
        command?.drafts[i].text = text
    }

    func discardDraft(_ id: UUID) {
        command?.drafts.removeAll { $0.id == id }
    }

    /// Sends the command bar's drafts you approved, through the outbox (so each can still be undone for a moment).
    func sendDrafts() async {
        guard let drafts = command?.drafts, !drafts.isEmpty else { return }
        command?.drafts = []
        for draft in drafts where !draft.text.trimmed.isEmpty {
            if let id = draft.chatID, let chat = chats.first(where: { $0.id == id }) {
                await send(draft.text.trimmed, to: chat)
            } else if let handle = draft.handle {
                _ = startConversation(with: handle, text: draft.text.trimmed)
            } else {
                continue
            }
            command?.sentCount += 1
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

    // MARK: - Limits

    /// AI replies with a "sending in…" notification showing (outbox id), so it can be updated or taken down.
    @ObservationIgnored var announced: Set<UUID> = []
    /// Conversations where auto-reply is paused because they sent a flood of texts: chat id → until when.
    var aiBlocks: [String: Date] = [:]
    @ObservationIgnored private var limitNotices: Set<String> = []

    private func rollDay() {
        let today = Date.now.formatted(.iso8601.year().month().day())
        guard config.stats.day != today else { return }
        config.stats.day = today
        config.stats.autoCallsToday = 0
        config.stats.spentToday = 0
    }

    /// Whether automatic AI work may run under today's limits; counts it when it may.
    func allowAutomatic(_ what: String, chat: String?) -> Bool {
        rollDay()
        let limits = config.limits
        if limits.autoCallsPerDay > 0, config.stats.autoCallsToday >= limits.autoCallsPerDay {
            limitReached("calls", "Reached today's limit of \(limits.autoCallsPerDay) automatic AI calls. Auto-replies and summaries resume tomorrow, or raise the limit in Settings › Limits.")
            return false
        }
        if config.provider == .openRouter, limits.dailySpendUSD > 0, config.stats.spentToday >= limits.dailySpendUSD {
            limitReached("spend", "Reached today's OpenRouter limit of $\(String(format: "%.2f", limits.dailySpendUSD)). Auto-replies and summaries resume tomorrow, or raise it in Settings › Limits.")
            return false
        }
        config.stats.autoCallsToday += 1
        return true
    }

    /// Logs (and notifies) once a day per limit.
    private func limitReached(_ kind: String, _ message: String) {
        guard limitNotices.insert(kind + config.stats.day).inserted else { return }
        log(.skipped, nil, message)
        if config.notifications.failures {
            Notifier.shared.post(title: "iMessager", subtitle: "AI paused for today", body: message, chat: nil)
        }
    }

    /// A chat sent a flood of texts: pause auto-reply there, and say so.
    func blockAI(_ chat: String, until: Date, texts: Int, minutes: Double) {
        aiBlocks[chat] = until
        let why = "\(texts) texts in \(Int(minutes.rounded())) min, so auto-reply is paused here for \(Int(until.timeIntervalSinceNow / 60 + 0.5)) min."
        log(.skipped, chat, why)
        if config.notifications.failures {
            Notifier.shared.post(title: title(for: chat), subtitle: "Auto-reply paused", body: why, chat: chat)
        }
    }

    func unblockAI(_ chat: String) {
        aiBlocks[chat] = nil
        Task { await agent?.unblock(chat) }
    }

    /// Adds one OpenRouter call's tokens and cost (USD) to the running totals.
    func recordUsage(_ usage: JSON?) {
        guard let usage else { return }
        rollDay()
        config.stats.spentToday += usage["cost"]?.number ?? 0
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

    /// Browser sign-in for a hosted MCP server, then reconnect with the new token.
    func signInMCP(_ id: UUID) {
        guard let item = config.integrations.first(where: { $0.id == id }), let url = URL(string: item.url.trimmed),
              url.scheme?.hasPrefix("http") == true else {
            integrationStatus[id] = "Add the server's URL first"
            return
        }
        integrationStatus[id] = "Finish signing in in your browser…"
        Task {
            do {
                try await MCPAuth.signIn(server: url, id: id)
                await restartIntegration(id)
            } catch {
                integrationStatus[id] = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    func useGitHubCLI(_ id: UUID) {
        guard let i = config.integrations.firstIndex(where: { $0.id == id }) else { return }
        do {
            try MCPAuth.useGitHubCLI(id: id, resource: config.integrations[i].url.trimmed)
            // Read-only unless you've chosen otherwise: replies are triggered by other people's texts.
            if !config.integrations[i].headers.lowercased().contains("x-mcp-readonly") {
                config.integrations[i].headers = (config.integrations[i].headers.trimmed + "\nX-MCP-Readonly: true").trimmed
            }
            // A leftover empty "Authorization: Bearer" line from the old preset would get in the way.
            config.integrations[i].headers = config.integrations[i].headers.split(separator: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != "authorization: bearer" }.joined(separator: "\n")
            config.integrations[i].notes = ""
            Task { await restartIntegration(id) }
        } catch {
            integrationStatus[id] = error.localizedDescription
        }
    }

    func signOutMCP(_ id: UUID) {
        MCPAuth.signOut(id)
        Task { await restartIntegration(id) }
    }

    func addPreset(_ preset: IntegrationPreset) {
        if preset == .googleCalendar, let i = config.integrations.firstIndex(where: { $0.kind == .calendar }) {
            config.integrations[i].enabled = true   // one calendar integration covers every account
        } else {
            config.integrations.append(.preset(preset))
        }
        if preset == .googleCalendar {
            // Google Calendar shows up in macOS Calendar once the account is added here.
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
        }
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
