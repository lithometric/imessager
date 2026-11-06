import Foundation
import Security

/// Per-conversation settings, keyed by chat.db `chat_identifier` (a phone/email for 1:1 chats).
struct ContactSettings: Codable, Hashable, Sendable {
    var enabled = false
    /// Switched off for this chat while "Auto-reply for everyone" is on.
    var disabled = false
    var instructions = ""
}

struct GreeterSettings: Codable, Hashable, Sendable {
    var enabled = false
    var instructions = "One friendly line, like “Great to meet you, Sarah! Saving your number now.”"
    var saveToContacts = true
    var enableAutoReply = false
}

enum IntegrationPreset: String, CaseIterable, Identifiable {
    case github, guava, googleCalendar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .github: "GitHub"
        case .guava: "Guava CRM"
        case .googleCalendar: "Google Calendar"
        }
    }
    var icon: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .guava: "person.2.badge.gearshape"
        case .googleCalendar: "calendar"
        }
    }
}

enum IntegrationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case profile, calendar, contacts, folder, webhook, mcp, remoteMCP, webSearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "About Me"
        case .calendar: "Calendar"
        case .contacts: "Contacts"
        case .folder: "Notes Folder"
        case .webhook: "Webhook / API"
        case .mcp: "MCP Server (local)"
        case .remoteMCP: "MCP Server (remote)"
        case .webSearch: "Web Search"
        }
    }

    var icon: String {
        switch self {
        case .profile: "person.text.rectangle"
        case .calendar: "calendar"
        case .contacts: "person.crop.circle"
        case .folder: "folder"
        case .webhook: "network"
        case .mcp: "server.rack"
        case .remoteMCP: "cloud"
        case .webSearch: "globe"
        }
    }

    var blurb: String {
        switch self {
        case .profile: "Facts about you, added to every prompt."
        case .calendar: "Your upcoming events, so the AI knows when you're free."
        case .contacts: "Lets the AI look up people's details: birthdays, companies, cities."
        case .folder: "Markdown/text files. Small folders go into the prompt; big ones get searched."
        case .webhook: "Any HTTP endpoint the AI can query: Zapier, n8n, your own server."
        case .mcp: "A Model Context Protocol server that runs on this Mac (npx, uvx, a binary…)."
        case .remoteMCP: "A hosted MCP server by URL with a token: GitHub, Guava CRM, Linear and others."
        case .webSearch: "Live web lookups through OpenRouter when the AI needs fresh facts."
        }
    }
}

struct IntegrationConfig: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var kind: IntegrationKind
    var name: String
    var enabled = true
    var notes = ""          // About Me text · webhook tool description
    var path = ""           // notes folder
    var url = ""            // webhook URL
    var method = "POST"     // webhook method
    var headers = ""        // webhook headers, "Key: value" per line
    var command = ""        // MCP launch command
    var env = ""            // MCP environment, "KEY=value" per line
    var days = 2            // calendar days injected into the prompt
    var model = ""          // web search model override

    /// One-click setups. Google Calendar comes through macOS Calendar (add the Google account in Internet Accounts).
    static func preset(_ preset: IntegrationPreset) -> IntegrationConfig {
        switch preset {
        case .github:
            var c = IntegrationConfig(kind: .remoteMCP, name: "GitHub")
            c.url = "https://api.githubcopilot.com/mcp/"
            // Read-only unless you change it: replies are triggered by other people's texts.
            c.headers = "X-MCP-Readonly: true"
            return c
        case .guava:
            var c = IntegrationConfig(kind: .remoteMCP, name: "Guava CRM")
            c.headers = "Authorization: Bearer "
            c.notes = "Paste Guava's MCP server URL, then Sign In with Browser (or paste an API token after “Bearer ”)."
            return c
        case .googleCalendar:
            var c = IntegrationConfig(kind: .calendar, name: "Google Calendar")
            c.days = 3
            return c
        }
    }

    static func new(_ kind: IntegrationKind) -> IntegrationConfig {
        var c = IntegrationConfig(kind: kind, name: kind.title)
        switch kind {
        case .folder: c.name = "Notes"
        case .webhook: c.name = "My API"
        case .mcp: c.name = "MCP"
        case .remoteMCP: c.name = "Remote MCP"
        default: break
        }
        return c
    }
}

extension IntegrationConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = try c.decode(IntegrationKind.self, forKey: .kind)
        name = c.value(.name, default: kind.title)
        enabled = c.value(.enabled, default: true)
        notes = c.value(.notes, default: "")
        path = c.value(.path, default: "")
        url = c.value(.url, default: "")
        method = c.value(.method, default: "POST")
        headers = c.value(.headers, default: "")
        command = c.value(.command, default: "")
        env = c.value(.env, default: "")
        days = c.value(.days, default: 2)
        model = c.value(.model, default: "")
    }
}

/// Running totals for the Home screen. Kept in config.json; messages themselves stay in chat.db.
struct AgentStats: Codable, Hashable, Sendable {
    var since = Date()
    var aiReplies = 0
    var greetings = 0
    var errors = 0
    var latencyTotalMs = 0
    var latencyCount = 0
    var costUSD = 0.0
    var promptTokens = 0
    var completionTokens = 0
    var calls = 0
    /// Today's automatic AI work (replies, greetings, summaries), for the daily limits. Resets at midnight.
    var day = ""
    var autoCallsToday = 0
    var spentToday = 0.0

    var averageLatencyMs: Int? { latencyCount > 0 ? latencyTotalMs / latencyCount : nil }
}

extension AgentStats {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = c.value(.since, default: Date())
        aiReplies = c.value(.aiReplies, default: 0)
        greetings = c.value(.greetings, default: 0)
        errors = c.value(.errors, default: 0)
        latencyTotalMs = c.value(.latencyTotalMs, default: 0)
        latencyCount = c.value(.latencyCount, default: 0)
        costUSD = c.value(.costUSD, default: 0)
        promptTokens = c.value(.promptTokens, default: 0)
        completionTokens = c.value(.completionTokens, default: 0)
        calls = c.value(.calls, default: 0)
        day = c.value(.day, default: "")
        autoCallsToday = c.value(.autoCallsToday, default: 0)
        spentToday = c.value(.spentToday, default: 0)
    }
}

/// Guards against someone spamming you (or a very busy group) running up your AI usage. Only automatic work is
/// limited: replies, greetings, unread summaries, the scheduled recap. Anything you start yourself always runs.
struct LimitSettings: Codable, Hashable, Sendable {
    var groupRepliesPerHour = 4          // per group chat (1:1 chats use maxRepliesPerHour)
    var secondsBetweenReplies = 30.0     // in one chat; texts that come sooner are answered together after
    var repliesPerHourAllChats = 40
    var autoCallsPerDay = 300
    var dailySpendUSD = 2.0              // OpenRouter; 0 = no cap
    var floodTexts = 12                  // this many texts…
    var floodMinutes = 2.0               // …this fast from one chat…
    var blockMinutes = 60.0              // …pauses auto-reply there this long

    static let defaults = LimitSettings()
}

extension LimitSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LimitSettings()
        groupRepliesPerHour = c.value(.groupRepliesPerHour, default: d.groupRepliesPerHour)
        secondsBetweenReplies = c.value(.secondsBetweenReplies, default: d.secondsBetweenReplies)
        repliesPerHourAllChats = c.value(.repliesPerHourAllChats, default: d.repliesPerHourAllChats)
        autoCallsPerDay = c.value(.autoCallsPerDay, default: d.autoCallsPerDay)
        dailySpendUSD = c.value(.dailySpendUSD, default: d.dailySpendUSD)
        floodTexts = c.value(.floodTexts, default: d.floodTexts)
        floodMinutes = c.value(.floodMinutes, default: d.floodMinutes)
        blockMinutes = c.value(.blockMinutes, default: d.blockMinutes)
    }
}

/// The daily recap on Home: when it's written (an hour of the day; morning covers yesterday, night covers today).
struct RecapSettings: Codable, Hashable, Sendable {
    var enabled = true
    var hour = 8
    var onCheck = TodoAction.draft
}

/// What checking off a recap to-do does in its conversation.
enum TodoAction: String, Codable, CaseIterable, Sendable {
    case draft      // open the chat with a reply written, for you to send
    case send       // write the reply and send it in the background
    case nothing    // just check it off
}

extension RecapSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecapSettings()
        enabled = c.value(.enabled, default: d.enabled)
        hour = c.value(.hour, default: d.hour)
        onCheck = c.value(.onCheck, default: d.onCheck)
    }
}

/// A few lines about a day of texts, and what you said you'd do (or were asked to), to check off.
struct Recap: Codable, Hashable, Sendable {
    var made: Date
    var from: Date
    var summary: String
    var todos: [Todo]

    struct Todo: Codable, Hashable, Sendable, Identifiable {
        var id = UUID()
        var text: String
        var chat: String?
        var done = false
        /// The text that went out (or was drafted) when you checked it off.
        var reply: String?
    }
}

/// Which events show a notification: new texts (like Messages) and what iMessager does for you.
struct NotificationSettings: Codable, Hashable, Sendable {
    var incoming = true
    var previews = true
    var aiReplies = true
    var greetings = true
    var failures = true
    var drafts = false
}

extension NotificationSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        incoming = c.value(.incoming, default: d.incoming)
        previews = c.value(.previews, default: d.previews)
        aiReplies = c.value(.aiReplies, default: d.aiReplies)
        greetings = c.value(.greetings, default: d.greetings)
        failures = c.value(.failures, default: d.failures)
        drafts = c.value(.drafts, default: d.drafts)
    }
}

/// Who writes the replies: OpenRouter with an API key, or your Claude plan through Claude Code.
enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openRouter, claudeCode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .claudeCode: "Claude plan"
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct AppConfig: Codable, Hashable, Sendable {
    var appearance = AppearanceMode.system
    /// How much of the desktop shows through the window, 0 (solid) to 1 (clearest glass).
    var transparency = 0.5
    var provider = AIProvider.openRouter
    /// AI replies for every person you text, unless you turn a chat off. Groups and strangers stay opt-in.
    var autoReplyEveryone = false
    /// AI replies in every group chat too (it only speaks when it's addressed or a reply is natural).
    var autoReplyGroups = false
    var summarizeUnread = true
    var recap = RecapSettings()
    var lastRecap: Recap?
    var notifications = NotificationSettings()
    var claudeCodeModel = "haiku"
    var claudeCodePath = ""     // blank = find it automatically
    var model = "anthropic/claude-haiku-5.5"
    var persona = AppConfig.defaultPersona
    var replyDelay = 1.0
    var historyLimit = 30
    var maxRepliesPerHour = 15
    var limits = LimitSettings()
    var pauseAfterManualMinutes = 10.0
    var dryRun = false
    var fastRouting = true
    var undoSendSeconds = 5.0
    /// While iMessager isn't the app in front, AI replies wait this long, with an Undo button in their notification.
    var aiUndoSeconds = 10.0
    var holdAIReplies = false
    var greeter = GreeterSettings()
    var contacts: [String: ContactSettings] = [:]
    var hiddenMessages: Set<String> = []     // chat.db message guids deleted in iMessager
    var hideAutomated = true                  // keep transactions and promotions out of the main list
    var chatKinds: [String: ChatKind] = [:]   // your corrections to the automatic sorting
    var stats = AgentStats()
    /// Read in iMessager up to this message date. Messages has no way for other apps to mark a chat read,
    /// so this clears the dot here; Messages and your phone keep their own read state.
    var readThrough: [String: Date] = [:]
    var markedUnread: Set<String> = []
    /// Also mark conversations read/unread in Messages (through Accessibility).
    var syncReadWithMessages = true
    /// One-time tips you've dismissed (e.g. turning off Messages' own notifications).
    var seenTips: Set<String> = []
    /// Fingerprints of the texts the AI sent in each chat (the latest 40), so "how you talk to them" is learned from
    /// your own texts only.
    var aiWritten: [String: [String]] = [:]
    /// Promotional senders you've texted STOP: chat id → when.
    var unsubscribed: [String: Date] = [:]
    /// Text STOP to promotional senders as their texts arrive (from `autoUnsubscribeSince` on).
    var autoUnsubscribe = false
    var autoUnsubscribeSince: Date?
    /// Your pins, in order (chat ids). Nil until you pin, unpin or reorder: until then Messages' own pins show.
    var pins: [String]?
    var integrations: [IntegrationConfig] = [
        IntegrationConfig(kind: .profile, name: "About Me"),
        IntegrationConfig(kind: .calendar, name: "Calendar", enabled: false),
        IntegrationConfig(kind: .webSearch, name: "Web Search", enabled: false),
    ]

    static let defaultPersona = """
    You are texting on my behalf from my own iMessage account. Write exactly like I text: casual, warm and brief, usually one short sentence. Lowercase is fine. No emojis unless they use them first. Match the other person's language and energy.

    - Answer what they actually asked. Use my calendar, notes and other context when it helps.
    - Don't invent facts about my life, and don't commit me to plans, money or favors unless my context clearly supports it. Say you'll check instead.
    - Don't share private details about me or anyone else beyond what the conversation calls for.
    - If someone sincerely asks whether they're talking to a bot, tell them the truth.
    """

    static let quickModels: [(id: String, label: String)] = [
        ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5 · fastest"),
        ("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5 · smartest everyday"),
        ("google/gemini-3.8-flash", "Gemini 3.8 Flash"),
        ("deepseek/deepseek-v4.1-flash", "DeepSeek V4.1 Flash · cheapest"),
    ]
}

extension ContactSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: false)
        disabled = c.value(.disabled, default: false)
        instructions = c.value(.instructions, default: "")
    }
}

extension GreeterSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GreeterSettings()
        enabled = c.value(.enabled, default: d.enabled)
        instructions = c.value(.instructions, default: d.instructions)
        saveToContacts = c.value(.saveToContacts, default: d.saveToContacts)
        enableAutoReply = c.value(.enableAutoReply, default: d.enableAutoReply)
    }
}

extension AppConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        appearance = c.value(.appearance, default: d.appearance)
        transparency = c.value(.transparency, default: d.transparency)
        provider = c.value(.provider, default: d.provider)
        autoReplyEveryone = c.value(.autoReplyEveryone, default: d.autoReplyEveryone)
        autoReplyGroups = c.value(.autoReplyGroups, default: d.autoReplyGroups)
        summarizeUnread = c.value(.summarizeUnread, default: d.summarizeUnread)
        recap = c.value(.recap, default: d.recap)
        lastRecap = c.value(.lastRecap, default: d.lastRecap)
        notifications = c.value(.notifications, default: d.notifications)
        claudeCodeModel = c.value(.claudeCodeModel, default: d.claudeCodeModel)
        claudeCodePath = c.value(.claudeCodePath, default: d.claudeCodePath)
        model = c.value(.model, default: d.model)
        persona = c.value(.persona, default: d.persona)
        replyDelay = c.value(.replyDelay, default: d.replyDelay)
        historyLimit = c.value(.historyLimit, default: d.historyLimit)
        maxRepliesPerHour = c.value(.maxRepliesPerHour, default: d.maxRepliesPerHour)
        limits = c.value(.limits, default: d.limits)
        pauseAfterManualMinutes = c.value(.pauseAfterManualMinutes, default: d.pauseAfterManualMinutes)
        dryRun = c.value(.dryRun, default: d.dryRun)
        fastRouting = c.value(.fastRouting, default: d.fastRouting)
        undoSendSeconds = c.value(.undoSendSeconds, default: d.undoSendSeconds)
        aiUndoSeconds = c.value(.aiUndoSeconds, default: d.aiUndoSeconds)
        holdAIReplies = c.value(.holdAIReplies, default: d.holdAIReplies)
        greeter = c.value(.greeter, default: d.greeter)
        contacts = c.value(.contacts, default: d.contacts)
        hiddenMessages = c.value(.hiddenMessages, default: d.hiddenMessages)
        hideAutomated = c.value(.hideAutomated, default: d.hideAutomated)
        chatKinds = c.value(.chatKinds, default: d.chatKinds)
        stats = c.value(.stats, default: d.stats)
        readThrough = c.value(.readThrough, default: d.readThrough)
        markedUnread = c.value(.markedUnread, default: d.markedUnread)
        syncReadWithMessages = c.value(.syncReadWithMessages, default: d.syncReadWithMessages)
        seenTips = c.value(.seenTips, default: d.seenTips)
        unsubscribed = c.value(.unsubscribed, default: d.unsubscribed)
        aiWritten = c.value(.aiWritten, default: d.aiWritten)
        autoUnsubscribe = c.value(.autoUnsubscribe, default: d.autoUnsubscribe)
        autoUnsubscribeSince = c.value(.autoUnsubscribeSince, default: d.autoUnsubscribeSince)
        pins = c.value(.pins, default: d.pins)
        integrations = c.value(.integrations, default: d.integrations)
    }
}

/// Settings live in one small JSON file. Messages themselves are never copied: chat.db is the only message store.
enum ConfigStore {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iMessager", isDirectory: true)
    static var file: URL { directory.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return config
    }

    static func save(_ config: AppConfig) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(config).write(to: file, options: .atomic)
    }
}

enum Keychain {
    private static let service = "com.lithometric.imessager"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
