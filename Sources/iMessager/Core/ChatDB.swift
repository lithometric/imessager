import Foundation
import SQLite3

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: Int64
    let text: String
    let isFromMe: Bool
    let date: Date
    let sender: String?
    let service: String
    let itemType: Int
    let associatedType: Int
    let chatGUID: String?
    let chatIdentifier: String?
    let chatStyle: Int
    var guid = ""
    var error = 0
    var isSent = false
    var isDelivered = false
    var dateRead: Date?
    var isEdited = false
    var isRetracted = false
    var hasAttachments = false
    var attachments: [Attachment] = []
    /// Inline replies: the message this one answers (the start of its thread).
    var threadOriginator: String?
    /// Tapbacks on this message, one per person (their latest).
    var reactions: [Reaction] = []

    var isGroup: Bool { chatStyle == 43 }

    /// The typed text without the "[attachment]" marker (the attachments render on their own).
    var caption: String {
        guard hasAttachments else { return text }
        return text.replacingOccurrences(of: "[attachment]", with: "").trimmed
    }
    var isTextMessage: Bool { service == "SMS" || service == "RCS" }

    /// What Messages shows under one of your texts. Nil for incoming messages.
    var status: DeliveryStatus? {
        guard isFromMe, !isRetracted else { return nil }
        if error != 0 { return .failed }
        if isTextMessage { return isSent || isDelivered ? .sentAsText : .sending }
        if let dateRead { return .read(dateRead) }
        if isDelivered { return .delivered }
        return isSent ? .sent : .sending
    }
}

/// A tapback: ❤️ 👍 👎 😂 ‼️ ❓, an emoji, or a sticker.
struct Reaction: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case love, like, dislike, laugh, emphasize, question, emoji(String), sticker
    }

    let kind: Kind
    let fromMe: Bool
    let sender: String?

    var symbol: String? {
        switch kind {
        case .love: "heart.fill"
        case .like: "hand.thumbsup.fill"
        case .dislike: "hand.thumbsdown.fill"
        case .emphasize: "exclamationmark.2"
        case .question: "questionmark"
        case .sticker: "face.smiling"
        case .laugh, .emoji: nil
        }
    }

    var verb: String {
        switch kind {
        case .love: "loved"
        case .like: "liked"
        case .dislike: "disliked"
        case .laugh: "laughed at"
        case .emphasize: "emphasized"
        case .question: "questioned"
        case .emoji(let e): "reacted \(e) to"
        case .sticker: "stuck a sticker on"
        }
    }

    /// chat.db codes: 2000–2007 add a tapback, 3000–3007 remove it.
    static func kind(type: Int, emoji: String?) -> Kind? {
        switch type % 1000 {
        case 0: .love
        case 1: .like
        case 2: .dislike
        case 3: .laugh
        case 4: .emphasize
        case 5: .question
        case 6: emoji.map { .emoji($0) } ?? .like
        case 7: .sticker
        default: nil
        }
    }
}

/// A photo, video or file on a message, as stored in ~/Library/Messages/Attachments.
struct Attachment: Hashable, Sendable, Identifiable {
    let path: String
    let mime: String?
    let name: String
    var id: String { path }

    var isImage: Bool { mime?.hasPrefix("image/") ?? false }
    var isVideo: Bool { mime?.hasPrefix("video/") ?? false }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// How the AI sees it in a transcript.
    var label: String { isImage ? "[photo]" : isVideo ? "[video]" : "[file: \(name)]" }
}

enum DeliveryStatus: Hashable, Sendable {
    case sending, sent, delivered, read(Date), sentAsText, failed

    var label: String {
        switch self {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .read(let date): "Read " + Fmt.receipt(date)
        case .sentAsText: "Sent as Text Message"
        case .failed: "Not Delivered"
        }
    }
}

/// Why chat.db can or can't be read, so the app can say exactly what to fix.
enum DBAccess: Equatable, Sendable {
    case checking
    case ok
    case noPermission     // macOS privacy (Full Disk Access) is blocking us
    case missing          // no chat.db: Messages was never set up on this Mac
    case failed(String)   // readable file, but SQLite couldn't use it
}

struct RawChat: Sendable {
    let identifier: String
    let guid: String
    let displayName: String?
    let isGroup: Bool
    let service: String
    let preview: String
    let lastFromMe: Bool
    let lastFailed: Bool
    let lastDate: Date
    let participants: [String]
    var lastSender: String?         // who sent the newest message, for "Maya: …" previews in groups
    var groupID: String?            // stable id Messages uses for groups across devices (and for pins)
    var samples: [String] = []      // latest incoming texts, for spotting automated senders
    var photoPath: String?          // group photo, from the chat's properties
}

/// Read-only access to Messages' own database (~/Library/Messages/chat.db).
/// iMessager never writes here and never mirrors it; every read is a live query.
actor ChatDB {
    static let path = NSHomeDirectory() + "/Library/Messages/chat.db"

    private var conn: SQLiteReader?
    private var columns = ""
    private var messageColumns: Set<String> = []
    private var chatColumns: Set<String> = []
    private var sampleCache: [String: (date: Date, texts: [String])] = [:]

    /// Status columns vary across macOS versions, so missing ones read as 0 instead of failing the query.
    private static let statusColumns = ["guid", "error", "is_sent", "is_delivered", "date_read", "date_edited", "date_retracted",
                                        "thread_originator_guid"]

    func probe() -> DBAccess {
        do {
            try run { try $0.query("SELECT 1 FROM message LIMIT 1") { _ in } }
            return .ok
        } catch {
            // SQLite errors are vague ("unable to open database file"); a plain open() tells privacy blocks from a missing file.
            let fd = open(Self.path, O_RDONLY)
            let code = errno
            if fd >= 0 {
                close(fd)
                return .failed(error.localizedDescription)
            }
            switch code {
            case EPERM, EACCES: return .noPermission
            case ENOENT: return .missing
            default: return .failed(String(cString: strerror(code)))
            }
        }
    }

    func maxRowID() throws -> Int64 {
        var id: Int64 = 0
        try run { try $0.query("SELECT IFNULL(MAX(ROWID), 0) FROM message") { id = $0.int(0) } }
        return id
    }

    /// Everything newer than `cursor`: one primary-key range scan, so polling costs microseconds.
    func messages(after cursor: Int64, limit: Int = 200) throws -> [ChatMessage] {
        var out: [ChatMessage] = []
        var seen = Set<Int64>()
        try run {
            try $0.query("""
                SELECT \(columns) FROM message m
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.ROWID > ? ORDER BY m.ROWID LIMIT ?
                """, [cursor, limit]) { row in
                let m = Self.message(row)
                if seen.insert(m.id).inserted { out.append(m) }
            }
        }
        return out
    }

    /// Latest messages for a conversation (all chat rows sharing the identifier, e.g. iMessage + SMS), oldest first.
    func history(identifier: String, limit: Int) throws -> [ChatMessage] {
        var out: [ChatMessage] = []
        try run {
            try $0.query("""
                SELECT \(columns) FROM chat c
                JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                JOIN message m ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE c.chat_identifier = ? AND m.associated_message_type = 0 AND m.item_type = 0
                ORDER BY cmj.message_date DESC LIMIT ?
                """, [identifier, limit]) { row in
                let m = Self.message(row)
                if !m.text.isEmpty || m.isRetracted { out.append(m) }
            }
            try attach(&out, db: $0)
            try react(&out, identifier: identifier, db: $0)
        }
        return out.reversed()
    }

    /// Tapbacks for the loaded messages: replayed in order, so a later change or removal wins.
    private func react(_ messages: inout [ChatMessage], identifier: String, db: SQLiteReader) throws {
        guard let oldest = messages.map(\.date).min(), messageColumns.contains("associated_message_guid") else { return }
        let emoji = messageColumns.contains("associated_message_emoji") ? "m.associated_message_emoji" : "NULL"
        var current: [String: [String: Reaction]] = [:]   // target guid → sender → reaction
        try db.query("""
            SELECT m.associated_message_guid, m.associated_message_type, \(emoji), m.is_from_me, h.id FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.chat_identifier = ? AND m.associated_message_type BETWEEN 2000 AND 3007 AND cmj.message_date >= ?
            ORDER BY cmj.message_date
            """, [identifier, Int64(oldest.timeIntervalSinceReferenceDate * 1_000_000_000) - 60_000_000_000]) { r in
            guard let raw = r.string(0) else { return }
            // "p:0/GUID" points at part 0 of a message; "bp:GUID" at the whole bubble.
            let target = raw.components(separatedBy: "/").last.map { $0.hasPrefix("bp:") ? String($0.dropFirst(3)) : $0 } ?? raw
            let type = Int(r.int(1))
            let fromMe = r.int(3) != 0
            let who = fromMe ? "me" : (r.string(4) ?? "?")
            if type >= 3000 {
                current[target]?[who] = nil
            } else if let kind = Reaction.kind(type: type, emoji: r.string(2)) {
                current[target, default: [:]][who] = Reaction(kind: kind, fromMe: fromMe, sender: fromMe ? nil : r.string(4))
            }
        }
        for i in messages.indices {
            if let found = current[messages[i].guid] { messages[i].reactions = Array(found.values) }
        }
    }

    /// Messages by guid (for quoting the message an inline reply answers when it's older than what's loaded).
    func messages(guids: [String]) throws -> [String: ChatMessage] {
        guard !guids.isEmpty else { return [:] }
        var out: [String: ChatMessage] = [:]
        let marks = Array(repeating: "?", count: guids.count).joined(separator: ",")
        try run {
            try $0.query("""
                SELECT \(columns) FROM message m
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.guid IN (\(marks))
                """, guids.map { $0 as Any? }) { let m = Self.message($0); out[m.guid] = m }
        }
        return out
    }

    /// Fills in attachments for messages that have them, in one query.
    private func attach(_ messages: inout [ChatMessage], db: SQLiteReader) throws {
        let ids = messages.filter(\.hasAttachments).map(\.id)
        guard !ids.isEmpty else { return }
        var byMessage: [Int64: [Attachment]] = [:]
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try db.query("""
            SELECT maj.message_id, a.filename, a.mime_type, a.transfer_name FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(marks)) ORDER BY maj.attachment_id
            """, ids.map { $0 as Any? }) { r in
            // Link previews are stored as hidden .pluginPayloadAttachment files; the link itself is in the text.
            guard let file = r.string(1), !file.hasSuffix(".pluginPayloadAttachment") else { return }
            let path = (file as NSString).expandingTildeInPath
            byMessage[r.int(0), default: []].append(
                Attachment(path: path, mime: r.string(2), name: r.string(3) ?? (path as NSString).lastPathComponent))
        }
        for i in messages.indices where messages[i].hasAttachments {
            messages[i].attachments = byMessage[messages[i].id] ?? []
        }
    }

    /// One message by ROWID, with its chat, for actions that name a specific message.
    func message(id: Int64) throws -> ChatMessage? {
        var found: ChatMessage?
        try run {
            try $0.query("""
                SELECT \(columns) FROM message m
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.ROWID = ? LIMIT 1
                """, [id]) { found = Self.message($0) }
        }
        return found
    }

    func search(identifier: String, query: String, scan: Int, limit: Int) throws -> [ChatMessage] {
        let terms = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }
        let scored = try history(identifier: identifier, limit: scan).compactMap { m -> (ChatMessage, Int)? in
            guard !m.isRetracted else { return nil }
            let text = m.text.lowercased()
            let score = terms.filter { text.contains($0) }.count
            return score > 0 ? (m, score) : nil
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
            .prefix(limit).map(\.0)
            .sorted { $0.date < $1.date }
    }

    func sentCount(identifier: String) throws -> Int {
        var n = 0
        try run {
            try $0.query("""
                SELECT COUNT(*) FROM chat c
                JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE c.chat_identifier = ? AND m.is_from_me = 1
                """, [identifier]) { n = Int($0.int(0)) }
        }
        return n
    }

    /// Newest conversations first. With `only`, just the chats whose identifier, guid or group id is listed
    /// (used for pinned chats that are older than the recent list).
    func recentChats(limit: Int, only: [String]? = nil) throws -> [RawChat] {
        let filter: String
        var args: [Any?] = []
        if let only {
            guard !only.isEmpty else { return [] }
            let marks = Array(repeating: "?", count: only.count).joined(separator: ",")
            let groupMatch = chatColumns.contains("group_id") ? " OR c.group_id IN (\(marks))" : ""
            filter = "WHERE c.chat_identifier IN (\(marks)) OR c.guid IN (\(marks))\(groupMatch)"
            args = (only + only + (groupMatch.isEmpty ? [] : only)).map { $0 as Any? }
        } else {
            filter = ""
        }
        struct Row { let rowID: Int64; let guid: String; let identifier: String; let displayName: String?; let style: Int
            let service: String; let preview: String; let fromMe: Bool; let failed: Bool; let date: Date; let properties: Data?
            let sender: String?; let groupID: String? }
        var rows: [Row] = []
        var seen = Set<String>()
        var chats: [RawChat] = []
        try run { db in
            try db.query("""
                SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.style, c.service_name,
                       m.text, m.attributedBody, m.is_from_me, m.date, m.cache_has_attachments, \(columns.contains("m.error") ? "m.error" : "0"),
                       \(chatColumns.contains("properties") ? "c.properties" : "NULL"), h.id,
                       \(chatColumns.contains("group_id") ? "c.group_id" : "NULL")
                FROM (SELECT chat_id, MAX(message_id) AS mid FROM chat_message_join GROUP BY chat_id) j
                JOIN chat c ON c.ROWID = j.chat_id
                JOIN message m ON m.ROWID = j.mid
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                \(filter)
                ORDER BY m.date DESC LIMIT ?
                """, args + [limit * 2]) { r in
                guard let guid = r.string(1), let identifier = r.string(2), seen.insert(identifier).inserted else { return }
                rows.append(Row(rowID: r.int(0), guid: guid, identifier: identifier, displayName: r.string(3),
                                style: Int(r.int(4)), service: r.string(5) ?? "iMessage",
                                preview: Self.previewText(r.string(6), r.data(7), hasAttachments: r.int(10) != 0),
                                fromMe: r.int(8) != 0, failed: r.int(8) != 0 && r.int(11) != 0, date: Self.appleDate(r.int(9)),
                                properties: r.data(12), sender: r.string(13), groupID: r.string(14)))
            }
            for row in rows.prefix(limit) {
                var participants: [String] = []
                var samples: [String] = []
                var photo: String?
                if row.style == 43 {
                    try db.query("""
                        SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = ?
                        """, [row.rowID]) { if let id = $0.string(0) { participants.append(id) } }
                    photo = try groupPhoto(db, row.properties)
                } else {
                    participants = [row.identifier]
                    samples = try incomingSamples(db, row.identifier, row.date)
                }
                var chat = RawChat(identifier: row.identifier, guid: row.guid, displayName: row.displayName,
                                   isGroup: row.style == 43, service: row.service, preview: row.preview,
                                   lastFromMe: row.fromMe, lastFailed: row.failed, lastDate: row.date, participants: participants)
                chat.samples = samples
                chat.lastSender = row.sender
                chat.groupID = row.groupID
                chat.photoPath = photo
                chats.append(chat)
            }
        }
        return chats
    }

    struct DayCount: Sendable, Identifiable {
        let day: Date
        var sent = 0
        var received = 0
        var id: Date { day }
    }

    struct MessageStats: Sendable {
        var sent = 0, received = 0
        var iMessagesSent = 0, delivered = 0, read = 0, failed = 0, textMessagesSent = 0
        var conversations = 0
        var days: [DayCount] = []
    }

    /// Delivery, read and volume numbers for the Home screen, straight from chat.db.
    func stats(days: Int) throws -> MessageStats {
        var out = MessageStats()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date()).addingTimeInterval(Double(-(days - 1)) * 86_400)
        var byDay: [Date: DayCount] = [:]
        var chats = Set<Int64>()
        let since = Int64(start.timeIntervalSinceReferenceDate * 1_000_000_000)
        let col = { (name: String) in self.messageColumns.contains(name) ? "m.\(name)" : "0" }
        try run { db in
            try db.query("""
                SELECT m.date, m.is_from_me, \(col("is_delivered")), \(col("date_read")), \(col("error")), m.service, cmj.chat_id
                FROM message m LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.date > ? AND m.item_type = 0 AND m.associated_message_type = 0
                """, [since]) { r in
                let date = Self.appleDate(r.int(0))
                let mine = r.int(1) != 0
                let day = cal.startOfDay(for: date)
                var bucket = byDay[day] ?? DayCount(day: day)
                chats.insert(r.int(6))
                if mine {
                    out.sent += 1
                    bucket.sent += 1
                    if r.int(4) != 0 { out.failed += 1 }
                    if ["SMS", "RCS"].contains(r.string(5) ?? "") {
                        out.textMessagesSent += 1
                    } else {
                        out.iMessagesSent += 1
                        if r.int(2) != 0 { out.delivered += 1 }
                        if r.int(3) > 0 { out.read += 1 }
                    }
                } else {
                    out.received += 1
                    bucket.received += 1
                }
                byDay[day] = bucket
            }
        }
        out.conversations = chats.count
        out.days = (0..<days).map { i in
            let day = cal.startOfDay(for: start.addingTimeInterval(Double(i) * 86_400 + 3600))
            return byDay[day] ?? DayCount(day: day)
        }
        return out
    }

    /// Unread incoming texts per conversation. Anything older than your last reply counts as read:
    /// replying reads the chat, and old rows can keep is_read = 0 forever after a sync.
    /// Dates of each conversation's unread texts, so read marks made in iMessager can be applied on top.
    func unreadDates() throws -> [String: [Date]] {
        var out: [String: [Date]] = [:]
        try run { db in
            guard messageColumns.contains("is_read") else { return }
            try db.query("""
                SELECT c.chat_identifier, cmj.message_date FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0
                  AND cmj.message_date > IFNULL((SELECT MAX(j2.message_date) FROM chat_message_join j2
                                                 JOIN message m2 ON m2.ROWID = j2.message_id
                                                 WHERE j2.chat_id = cmj.chat_id AND m2.is_from_me = 1), 0)
                """) { r in if let id = r.string(0) { out[id, default: []].append(Self.appleDate(r.int(1))) } }
        }
        return out
    }

    /// The last few texts they sent, cached until the conversation changes.
    private func incomingSamples(_ db: SQLiteReader, _ identifier: String, _ lastDate: Date) throws -> [String] {
        if let cached = sampleCache[identifier], cached.date == lastDate { return cached.texts }
        var texts: [String] = []
        try db.query("""
            SELECT m.text, m.attributedBody FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE c.chat_identifier = ? AND m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0
            ORDER BY cmj.message_date DESC LIMIT 3
            """, [identifier]) { r in
            let t = Self.bodyText(r.string(0), r.data(1), hasAttachments: false)
            if !t.isEmpty { texts.append(t) }
        }
        sampleCache[identifier] = (lastDate, texts)
        return texts
    }

    /// Group photos are attachments; the chat's properties plist names which one.
    private func groupPhoto(_ db: SQLiteReader, _ properties: Data?) throws -> String? {
        guard let properties,
              let plist = try? PropertyListSerialization.propertyList(from: properties, format: nil) as? [String: Any],
              let guid = plist["groupPhotoGuid"] as? String else { return nil }
        var path: String?
        try db.query("SELECT filename FROM attachment WHERE guid = ? LIMIT 1", [guid]) { path = $0.string(0) }
        return path.map { ($0 as NSString).expandingTildeInPath }
    }

    // MARK: - Internals

    private func reader() throws -> SQLiteReader {
        if let conn { return conn }
        let c = try SQLiteReader(path: Self.path)
        var have = Set<String>()
        try c.query("PRAGMA table_info(message)") { if let name = $0.string(1) { have.insert(name) } }
        messageColumns = have
        chatColumns = []
        try c.query("PRAGMA table_info(chat)") { if let name = $0.string(1) { self.chatColumns.insert(name) } }
        columns = """
            m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date, m.service, m.associated_message_type,
            m.item_type, m.cache_has_attachments, h.id, c.guid, c.chat_identifier, c.style,
            """ + Self.statusColumns.map { have.contains($0) ? "m.\($0)" : ($0.hasSuffix("_guid") ? "NULL" : "0") }.joined(separator: ", ")
        conn = c
        return c
    }

    private func run(_ body: (SQLiteReader) throws -> Void) throws {
        do { try body(try reader()) } catch {
            conn = nil // reopen next time (e.g. access was revoked or the file was replaced)
            throw error
        }
    }

    private static func message(_ r: SQLiteReader.Row) -> ChatMessage {
        var m = ChatMessage(
            id: r.int(0),
            text: bodyText(r.string(1), r.data(2), hasAttachments: r.int(8) != 0),
            isFromMe: r.int(3) != 0,
            date: appleDate(r.int(4)),
            sender: r.string(9),
            service: r.string(5) ?? "iMessage",
            itemType: Int(r.int(7)),
            associatedType: Int(r.int(6)),
            chatGUID: r.string(10),
            chatIdentifier: r.string(11),
            chatStyle: Int(r.int(12))
        )
        m.guid = r.string(13) ?? String(m.id)
        m.hasAttachments = r.int(8) != 0
        m.error = Int(r.int(14))
        m.isSent = r.int(15) != 0
        m.isDelivered = r.int(16) != 0
        m.dateRead = r.int(17) > 0 ? appleDate(r.int(17)) : nil
        // Unsending blanks the text and stamps the edit date; editing keeps the text.
        m.isRetracted = r.int(19) > 0 || (r.int(18) > 0 && m.text.isEmpty)
        m.isEdited = r.int(18) > 0 && !m.isRetracted
        m.threadOriginator = r.string(20).flatMap { $0.isEmpty ? nil : $0 }
        return m
    }

    /// Message dates are seconds (old) or nanoseconds (High Sierra+) since 2001-01-01.
    static func appleDate(_ raw: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw))
    }

    static func bodyText(_ text: String?, _ blob: Data?, hasAttachments: Bool) -> String {
        var t = text ?? ""
        if t.trimmed.isEmpty, let blob { t = decodeAttributedBody(blob) ?? "" }
        t = visible(t)
        if hasAttachments { return t.isEmpty ? "[attachment]" : "[attachment] \(t)" }
        return t
    }

    /// What the conversation list shows, like Messages: the text, or "Attachment" when there's only a photo or file.
    static func previewText(_ text: String?, _ blob: Data?, hasAttachments: Bool) -> String {
        var t = text ?? ""
        if t.trimmed.isEmpty, let blob { t = decodeAttributedBody(blob) ?? "" }
        t = visible(t)
        return t.isEmpty && hasAttachments ? "Attachment" : t
    }

    /// Drops the placeholders Messages stores in message text (attachment markers, stray control and private-use
    /// characters) that would otherwise draw as "?" boxes. Emoji joiners and variation selectors stay.
    static func visible(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { u in
            if u.value == 0xFFFC || u.value == 0xFFFD { return false }
            switch u.properties.generalCategory {
            case .control: return u == "\n" || u == "\t"
            case .privateUse, .unassigned, .surrogate: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(kept)).trimmed
    }

    /// Newer macOS stores message text only in `attributedBody`, an NSAttributedString typedstream.
    /// The string follows the "NSString" class marker: `… 0x2B <length> <utf8 bytes>`.
    static func decodeAttributedBody(_ data: Data) -> String? {
        guard let marker = data.range(of: Data("NSString".utf8)) else { return nil }
        let bytes = [UInt8](data[marker.upperBound...])
        guard let plus = bytes.prefix(16).firstIndex(of: 0x2B) else { return nil }
        var i = plus + 1
        guard i < bytes.count else { return nil }
        var length = 0
        switch bytes[i] {
        case 0x81:
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
            i += 3
        case 0x82:
            guard i + 4 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) << 16 | Int(bytes[i + 4]) << 24
            i += 5
        default:
            length = Int(bytes[i])
            i += 1
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(decoding: bytes[i..<(i + length)], as: UTF8.self)
    }
}

/// Read-only SQLite connection with a prepared-statement cache.
final class SQLiteReader {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func string(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        func data(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    init(path: String) throws {
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Couldn't open chat.db"
            sqlite3_close(db)
            db = nil
            throw AppError(message)
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(db)
    }

    func query(_ sql: String, _ args: [Any?] = [], _ row: (Row) throws -> Void) throws {
        let stmt = try prepare(sql)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try row(Row(stmt: stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw AppError(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK, let stmt else {
            throw AppError(String(cString: sqlite3_errmsg(db)))
        }
        statements[sql] = stmt
        return stmt
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
