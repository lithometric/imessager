import Foundation

/// Unsubscribing from promotional texts: replying STOP, the opt-out every US carrier honors for business senders.
extension AppState {
    /// Senders you could unsubscribe from: chats sorted into Promotions, from a number or short code. Never
    /// Transactions (codes, banks, deliveries), your contacts, groups, email senders, or anyone you've texted yourself.
    var unsubscribeCandidates: [ChatSummary] {
        chats.filter { chat in
            chat.kind == .promotion && !chat.isGroup && !chat.isKnown && !chat.id.contains("@")
                && (!chat.hasMine || config.unsubscribed[chat.id] != nil)
        }
    }

    /// Whether they've kept texting well after you sent STOP (a confirmation right after doesn't count).
    func stillTexting(_ chat: ChatSummary) -> Bool {
        guard let sent = config.unsubscribed[chat.id] else { return false }
        return !chat.lastFromMe && chat.lastDate > sent.addingTimeInterval(24 * 3600)
    }

    /// Texts STOP to each, through the outbox (so each can still be undone for a moment).
    func unsubscribe(_ ids: [String]) async {
        let targets = ids.compactMap { id in chats.first { $0.id == id } }
        for chat in targets { config.unsubscribed[chat.id] = .now }   // first, so a refresh meanwhile can't send twice
        for chat in targets {
            await send("STOP", to: chat)
            log(.info, chat.id, "Texted STOP to unsubscribe")
        }
    }

    /// With automatic unsubscribing on: promotional senders that text after you turned it on get STOP, 10 a day at most
    /// (in case the sorting gets one wrong, it can't run away).
    func unsubscribeNew() {
        guard config.autoUnsubscribe, let since = config.autoUnsubscribeSince else { return }
        let fresh = unsubscribeCandidates.filter { config.unsubscribed[$0.id] == nil && !$0.lastFromMe && $0.lastDate > since }
        guard !fresh.isEmpty else { return }
        let sentToday = config.unsubscribed.values.filter { Calendar.current.isDateInToday($0) }.count
        let batch = fresh.prefix(max(0, 10 - sentToday)).map(\.id)
        guard !batch.isEmpty else { return }
        Task { await unsubscribe(Array(batch)) }
    }
}
