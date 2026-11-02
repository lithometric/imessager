import Foundation

enum SendOrigin: Sendable {
    case you, ai, greeter
}

/// A text on its way out. Lives only in memory: once Messages has it, chat.db is the record.
struct OutgoingMessage: Identifiable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued, sending, sent, failed(String)
    }

    let id = UUID()
    let chat: String
    let guid: String
    let handle: String?
    let text: String
    /// A staged photo, video or file (see `Staging`); sent as its own message, like Messages does.
    var attachment: URL?
    let origin: SendOrigin
    var asTextMessage = false
    let created = Date()
    var sendAt: Date
    var phase: Phase = .queued
    var ms: Int?
    var detail: String?

    /// Short id the model can name in tool calls ("q-1a2b3c").
    var ref: String { "q-" + id.uuidString.prefix(6).lowercased() }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var phaseLabel: String {
        switch phase {
        case .queued: "waiting to send (\(max(1, Int(sendAt.timeIntervalSinceNow.rounded(.up))))s left, can be undone)"
        case .sending: "sending"
        case .sent: "sent"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

/// Undo send, Try Again and Send as Text Message. Messages has no scripting for unsend or delete,
/// so undo works by holding each text for a few seconds before handing it to Messages.
extension AppState {
    @discardableResult
    func enqueue(_ text: String, chat: String, guid: String, handle: String?, origin: SendOrigin, attachment: URL? = nil,
                 asTextMessage: Bool = false, hold: Double? = nil, ms: Int? = nil, detail: String? = nil) -> OutgoingMessage {
        let wait = hold ?? (origin == .you || config.holdAIReplies ? max(0, config.undoSendSeconds) : 0)
        let item = OutgoingMessage(chat: chat, guid: guid, handle: handle, text: text, attachment: attachment, origin: origin,
                                   asTextMessage: asTextMessage, sendAt: Date().addingTimeInterval(wait), ms: ms, detail: detail)
        outbox.append(item)
        schedule(item.id, after: wait)
        return item
    }

    func outbox(for chat: String) -> [OutgoingMessage] {
        outbox.filter { $0.chat == chat }
    }

    func outgoing(ref: String, chat: String) -> OutgoingMessage? {
        outbox.first { $0.ref == ref.lowercased() && $0.chat == chat }
    }

    /// Pulls a queued text back before it reaches Messages, and returns it so the composer can restore it.
    @discardableResult
    func undoSend(_ id: UUID) -> OutgoingMessage? {
        guard let i = outbox.firstIndex(where: { $0.id == id }), outbox[i].phase == .queued else { return nil }
        outboxTimers.removeValue(forKey: id)?.cancel()
        let item = outbox.remove(at: i)
        log(.info, item.chat, "Unsent before it went out: \(item.text)")
        return item
    }

    /// Try Again (or Send as Text Message) for a text that failed on its way to Messages.
    func retry(_ id: UUID, asTextMessage: Bool) {
        guard let i = outbox.firstIndex(where: { $0.id == id }), outbox[i].isFailed else { return }
        outbox[i].phase = .queued
        outbox[i].asTextMessage = asTextMessage
        outbox[i].sendAt = Date()
        schedule(id, after: 0)
    }

    /// Deletes a queued or failed text. One that's mid-send can't be stopped.
    func discard(_ id: UUID) {
        outboxTimers.removeValue(forKey: id)?.cancel()
        outbox.removeAll { $0.id == id && $0.phase != .sending }
    }

    /// Try Again for a text Messages couldn't deliver: sends a fresh copy right away and hides the failed one.
    @discardableResult
    func resend(_ message: ChatMessage, guid: String, handle: String?, asTextMessage: Bool, origin: SendOrigin = .you) -> OutgoingMessage {
        hide(message)
        return enqueue(message.text, chat: message.chatIdentifier ?? "", guid: guid, handle: handle, origin: origin,
                       asTextMessage: asTextMessage, hold: 0, detail: asTextMessage ? "Resent as a text message" : "Resent")
    }

    // MARK: - Deleting (iMessager only: chat.db is never written)

    func isHidden(_ message: ChatMessage) -> Bool { config.hiddenMessages.contains(message.guid) }

    func hide(_ message: ChatMessage) { config.hiddenMessages.insert(message.guid) }

    func unhide(_ message: ChatMessage) { config.hiddenMessages.remove(message.guid) }

    // MARK: - Dispatch

    private func schedule(_ id: UUID, after delay: Double) {
        outboxTimers[id]?.cancel()
        outboxTimers[id] = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await dispatch(id)
        }
    }

    private func dispatch(_ id: UUID) async {
        outboxTimers[id] = nil
        guard let i = outbox.firstIndex(where: { $0.id == id }), outbox[i].phase == .queued else { return }
        outbox[i].phase = .sending
        let item = outbox[i]
        // Your own texts are left to look like manual replies, so the agent steps back for this chat.
        if item.origin != .you { await agent?.expectEcho(item.chat, item.text) }
        let result = Result {
            if let file = item.attachment {
                try sender.sendFile(file, chatGUID: item.guid, handle: item.handle, asTextMessage: item.asTextMessage)
            } else {
                try sender.send(item.text, chatGUID: item.guid, handle: item.handle, asTextMessage: item.asTextMessage)
            }
        }
        guard let j = outbox.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success:
            outbox[j].phase = .sent
            if item.origin != .you {
                config.stats.aiReplies += item.origin == .ai ? 1 : 0
                config.stats.greetings += item.origin == .greeter ? 1 : 0
                if let ms = item.ms {
                    config.stats.latencyTotalMs += ms
                    config.stats.latencyCount += 1
                }
            }
            log(item.origin == .greeter ? .greeted : .sent, item.chat, item.text, ms: item.ms,
                detail: [item.asTextMessage ? "Text message" : nil, item.detail].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
            if item.origin == .ai, config.notifications.aiReplies {
                Notifier.shared.post(title: title(for: item.chat), subtitle: "AI replied for you", body: item.text, chat: item.chat)
            } else if item.origin == .greeter, config.notifications.greetings {
                Notifier.shared.post(title: title(for: item.chat), subtitle: "New contact greeted", body: item.text, chat: item.chat)
            }
            // The chat.db copy replaces this one in the transcript within a second or two.
            Task {
                try? await Task.sleep(for: .seconds(30))
                outbox.removeAll { $0.id == id && $0.phase == .sent }
            }
        case .failure(let error):
            outbox[j].phase = .failed(error.localizedDescription)
            log(.error, item.chat, "Couldn't send “\(item.attachment?.lastPathComponent ?? String(item.text.prefix(80)))”: \(error.localizedDescription)")
            if config.notifications.failures {
                Notifier.shared.post(title: title(for: item.chat), subtitle: "Couldn't send",
                                     body: item.attachment?.lastPathComponent ?? item.text, chat: item.chat, outboxID: id, failed: true)
            }
        }
    }
}

/// Copies of photos and files you're sending, kept where Messages can read them until they've gone out.
/// (Desktop, Documents and Downloads are privacy-protected, so Messages may not be allowed to read originals there.)
enum Staging {
    static let directory = ContactsIndex.cacheDirectory.appendingPathComponent("outgoing", isDirectory: true)

    static func stage(_ url: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    static func stage(_ data: Data, name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    /// Clears copies older than a day (Messages has long since picked them up).
    static func sweep() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: folder) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
