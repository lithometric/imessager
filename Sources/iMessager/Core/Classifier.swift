import Foundation

/// Where a conversation belongs, like Messages' own filters.
/// Transactions and promotions stay out of the main list.
enum ChatKind: String, Codable, Sendable {
    case person, transaction, promotion
}

/// Spots automated texts (payment alerts, codes, deliveries, marketing) from the sender and the wording.
/// Only unknown 1:1 senders are checked: people in your Contacts and group chats are always conversations.
enum Classifier {
    static func classify(handle: String, texts: [String], known: Bool, isGroup: Bool) -> ChatKind {
        guard !isGroup, !known else { return .person }
        let text = texts.joined(separator: "\n").lowercased()
        let promo = score(text, promotionSignals) + regexHits(text, promotionPatterns) * 2
        let notice = score(text, transactionSignals) + regexHits(text, paymentPatterns) + regexHits(text, transactionPatterns) * 3

        if isShortCode(handle) || isNoReply(handle) {
            return promo > notice ? .promotion : .transaction
        }
        // Real people rarely write "reply STOP"; one strong marketing marker is enough.
        // People do say "sent you $20", so from a normal number that alone isn't enough.
        if promo >= 2 { return .promotion }
        if notice >= 3 { return .transaction }
        return .person
    }

    /// 5–6 digit senders are carrier short codes: banks, Venmo, airlines, stores.
    static func isShortCode(_ handle: String) -> Bool {
        let digits = handle.filter(\.isNumber)
        return !handle.contains("@") && (3...6).contains(digits.count) && digits.count == handle.filter { !$0.isWhitespace }.count
    }

    private static func isNoReply(_ handle: String) -> Bool {
        let h = handle.lowercased()
        return h.contains("noreply") || h.contains("no-reply") || h.contains("donotreply") || h.contains("notification")
    }

    private static func score(_ text: String, _ signals: [String]) -> Int {
        signals.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }

    private static func regexHits(_ text: String, _ patterns: [NSRegularExpression]) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.reduce(0) { $0 + ($1.firstMatch(in: text, range: range) != nil ? 1 : 0) }
    }

    /// Compiled once; classification runs for every chat on every refresh.
    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    private static let promotionPatterns = compile([
        #"\b(reply|text|txt|send|msg)\s+stop\b"#,
        #"\bstop\s+(to\s+)?(end|opt|unsub|cancel|quit|stop)"#,
        #"\bmsg\s*(&|and)\s*data\s*rates"#,
        #"\b\d{1,2}%\s*off\b"#,
    ])

    private static let promotionSignals = [
        "unsubscribe", "opt out", "opt-out", "promo code", "use code", "limited time", "shop now", "sale ends",
        "free shipping", "exclusive offer", "don't miss", "last chance", "deal of", "flash sale", "% off", "rewards members",
        "click here", "buy now", "new arrivals", "giveaway", "you've been selected", "claim your",
    ]

    private static let transactionPatterns = compile([
        #"\b(verification|security|login|sign-in|confirmation|access)\s+code\b"#,
        #"\b(code|pin|otp)\s*(is|:)\s*\d{4,8}\b"#,
        #"\bcard ending( in)?\s*\d{4}\b|\baccount ending( in)?\s*\d{4}\b"#,
        #"\b(out for delivery|has shipped|was delivered|tracking number)\b"#,
    ])

    private static let paymentPatterns = compile([
        #"\bpaid you\b|\bsent you \$|\byou (received|got paid)|\bdeposit(ed)?\b"#,
    ])

    private static let transactionSignals = [
        "venmo", "cash app", "zelle", "paypal", "apple cash", "payment", "transaction", "purchase", "balance", "charged",
        "your order", "order #", "shipped", "delivered", "package", "appointment", "reminder", "do not share", "don't share",
        "one-time", "passcode", "2fa", "alert:", "fraud", "account", "statement", "receipt", "invoice", "refund", "bank",
        "do not reply", "reservation", "boarding pass",
    ]
}
