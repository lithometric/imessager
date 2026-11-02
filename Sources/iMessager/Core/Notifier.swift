import AppKit
import UserNotifications

/// macOS notifications for what iMessager does on your behalf: AI replies, new-contact greetings, drafts and
/// texts that couldn't be sent. (They're local notifications: everything runs on this Mac, so there's no push server.)
/// Incoming texts are left to Messages so nothing shows twice. Clicking one opens that conversation.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    private static let failedCategory = "failed"
    private static let messageCategory = "message"
    private static let retryAction = "retry"
    private static let replyAction = "reply"
    private static let readAction = "read"

    /// macOS only gives notifications to a real .app bundle (it aborts otherwise, e.g. under `swift run`).
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let retry = UNNotificationAction(identifier: Self.retryAction, title: "Try Again")
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "iMessage")
        let read = UNNotificationAction(identifier: Self.readAction, title: "Mark as Read")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.failedCategory, actions: [retry], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.messageCategory, actions: [reply, read], intentIdentifiers: []),
        ])
        requestPermission()
    }

    /// Asks macOS once (it remembers the answer), and notes what it said for troubleshooting.
    func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            let line = "\(Date()): notifications \(granted ? "allowed" : "not allowed")\(error.map { " (\($0.localizedDescription))" } ?? "")\n"
            let log = ContactsIndex.cacheDirectory.appendingPathComponent("notifications.log")
            try? FileManager.default.createDirectory(at: ContactsIndex.cacheDirectory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: log)
            }
            Task { @MainActor in AppState.shared.notificationsAllowed = granted }
        }
    }

    /// Whether macOS lets iMessager show notifications at all.
    func allowed() async -> Bool {
        guard available else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }

    /// A new text, like Messages: sender as the title, the group as the subtitle, their photo, Reply and Mark as Read.
    func postMessage(title: String, subtitle: String?, body: String, chat: String, photo: NSImage?) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.messageCategory
        content.threadIdentifier = chat
        content.userInfo = ["chat": chat]
        if let photo, let tiff = photo.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let dir = ContactsIndex.cacheDirectory.appendingPathComponent("notifications", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(UUID().uuidString + ".png")
            if (try? png.write(to: file)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "photo", url: file) {
                content.attachments = [attachment]
            }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func post(title: String, subtitle: String, body: String, chat: String?, outboxID: UUID? = nil, failed: Bool = false) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = failed ? .default : nil
        if failed { content.categoryIdentifier = Self.failedCategory }
        var info: [String: String] = [:]
        if let chat { info["chat"] = chat }
        if let outboxID { info["outbox"] = outboxID.uuidString }
        content.userInfo = info
        content.threadIdentifier = chat ?? "imessager"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Like Messages: no banner for the conversation you're reading; everything else pops up.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let chat = content.userInfo["chat"] as? String
        Task { @MainActor in
            let reading = NSApp.isActive && chat != nil && AppState.shared.viewingChat == chat
            if content.categoryIdentifier == Self.messageCategory {
                done(reading ? [] : [.banner, .list, .sound])
            } else {
                done(NSApp.isActive && content.categoryIdentifier != Self.failedCategory ? [.list] : [.banner, .list, .sound])
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let chat = info["chat"] as? String
        let outbox = (info["outbox"] as? String).flatMap(UUID.init(uuidString:))
        let retry = response.actionIdentifier == Self.retryAction
        let typed = (response as? UNTextInputNotificationResponse)?.userText.trimmed
        let markRead = response.actionIdentifier == Self.readAction
        Task { @MainActor in
            let state = AppState.shared
            if retry, let outbox {
                state.retry(outbox, asTextMessage: false)
            } else if let typed, !typed.isEmpty, let chat, let summary = state.chats.first(where: { $0.id == chat }) {
                await state.send(typed, to: summary)
                state.markRead(chat)
            } else if markRead, let chat {
                state.markRead(chat)
            } else {
                NSApp.activate()
                AppState.shared.openRequest = chat
            }
            done()
        }
    }
}
