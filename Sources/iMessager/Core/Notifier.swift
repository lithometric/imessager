import AppKit
import Intents
import Security
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
    private static let aiReplyAction = "aiReply"
    private static let sendingCategory = "aiSending"
    private static let undoAction = "undo"

    /// macOS only gives notifications to a real .app bundle (it aborts otherwise, e.g. under `swift run`).
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerActions(aiName: "AI")
        requestPermission()
    }

    /// The buttons on notifications. "Reply with Claude" (or AI) answers from the notification, even with auto-reply off.
    func registerActions(aiName: String) {
        guard available else { return }
        let retry = UNNotificationAction(identifier: Self.retryAction, title: "Try Again")
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "iMessage")
        let aiReply = UNNotificationAction(identifier: Self.aiReplyAction, title: "Reply with \(aiName)")
        let read = UNNotificationAction(identifier: Self.readAction, title: "Mark as Read")
        let undo = UNNotificationAction(identifier: Self.undoAction, title: "Undo")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.sendingCategory, actions: [undo], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.failedCategory, actions: [retry], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.messageCategory, actions: [reply, aiReply, read], intentIdentifiers: []),
        ])
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
    /// With the Communication Notifications capability, macOS shows their photo as the notification's picture with
    /// iMessager's icon small in its corner, like Messages; without it, the photo sits on the right instead.
    func postMessage(title: String, subtitle: String?, body: String, chat: String, handle: String, photo: NSImage?) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.messageCategory
        content.threadIdentifier = chat
        content.userInfo = ["chat": chat]
        let png = photo.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        if let styled = Self.asConversation(content, from: title, handle: handle, group: subtitle, chat: chat, photo: png) {
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: styled, trigger: nil))
            return
        }
        if let png {
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

    /// Whether this build is signed with the Communication Notifications capability (it needs a provisioning profile).
    private static let canStyleAsConversation: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.usernotifications.communication" as CFString, nil)
        return (value as? Bool) == true
    }()

    /// Messages' look: the sender (with their photo) as a message intent. macOS only accepts this from an app signed
    /// with the Communication Notifications capability; otherwise it throws and the plain style is used.
    private static func asConversation(_ content: UNMutableNotificationContent, from name: String, handle: String,
                                       group: String?, chat: String, photo: Data?) -> UNNotificationContent? {
        guard canStyleAsConversation else { return nil }
        let kind: INPersonHandleType = handle.contains("@") ? .emailAddress : .phoneNumber
        let sender = INPerson(personHandle: INPersonHandle(value: handle, type: kind), nameComponents: nil, displayName: name,
                              image: photo.map { INImage(imageData: $0) }, contactIdentifier: nil, customIdentifier: handle)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: group.map { INSpeakableString(spokenPhrase: $0) },
                                         conversationIdentifier: chat, serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return try? content.updating(from: intent)
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

    /// An AI reply on its way out ("sends in 10 s", with Undo), then the same notification again once it's sent.
    func postAIReply(_ id: UUID, chat: String, title: String, text: String, status: String, undo: Bool) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = status
        content.body = text
        content.sound = nil
        if undo {
            content.categoryIdentifier = Self.sendingCategory
        } else {
            content.interruptionLevel = .passive   // the "sent" update replaces it quietly, no second banner
        }
        content.threadIdentifier = chat
        content.userInfo = ["chat": chat, "outbox": id.uuidString, "update": undo ? "" : "1"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ai-\(id.uuidString)", content: content, trigger: nil))
    }

    func removeAIReply(_ id: UUID) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["ai-\(id.uuidString)"])
        center.removePendingNotificationRequests(withIdentifiers: ["ai-\(id.uuidString)"])
    }

    // Like Messages: no banner for the conversation you're reading; everything else pops up.
    // A "sent" update to a reply you were already told about just changes it in Notification Center.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let chat = content.userInfo["chat"] as? String
        Task { @MainActor in
            let reading = NSApp.isActive && chat != nil && AppState.shared.viewingChat == chat
            if content.categoryIdentifier == Self.messageCategory {
                done(reading ? [] : [.banner, .list, .sound])
            } else if content.userInfo["update"] as? String == "1" {
                done([.list])
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
        let aiReply = response.actionIdentifier == Self.aiReplyAction
        let undo = response.actionIdentifier == Self.undoAction
        Task { @MainActor in
            let state = AppState.shared
            if undo, let outbox {
                state.undoAIReply(outbox)
            } else if retry, let outbox {
                state.retry(outbox, asTextMessage: false)
            } else if aiReply, let chat {
                await state.aiReply(to: chat)
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
