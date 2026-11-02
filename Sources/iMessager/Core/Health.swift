import AppKit
import Contacts

/// An in-app notification card. Most are derived live from the health check; `transientNotices` hold one-off confirmations.
struct AppNotice: Identifiable, Equatable {
    enum Kind { case error, warning, info, success }

    let id: String
    let kind: Kind
    let title: String
    let message: String
    var dismissible = true
}

extension AppState {
    /// Something blocks reading chat.db, writing replies, or sending them.
    var needsSetup: Bool {
        dbAccess != .ok || !aiReady || automation == -1743
    }

    var notices: [AppNotice] {
        var out: [AppNotice] = []
        switch dbAccess {
        case .noPermission:
            out.append(AppNotice(
                id: "fda", kind: .error, title: "Turn on Full Disk Access",
                message: "macOS is blocking iMessager from reading your messages in ~/Library/Messages/chat.db. Switch it on in System Settings. This card disappears by itself once it works.",
                dismissible: false))
        case .missing:
            out.append(AppNotice(
                id: "db-missing", kind: .warning, title: "No Messages database on this Mac",
                message: "chat.db doesn't exist yet. Open Messages, sign in to iMessage, and it will appear.",
                dismissible: false))
        case .failed(let reason):
            out.append(AppNotice(
                id: "db-error", kind: .error, title: "Can't open chat.db",
                message: "\(reason). Relaunching usually fixes this.", dismissible: false))
        case .checking, .ok:
            break
        }

        if dbAccess == .ok {
            if config.provider == .openRouter, apiKey.trimmed.isEmpty {
                out.append(AppNotice(id: "key", kind: .info, title: "Connect an AI",
                                     message: "iMessager can read your chats. Add an OpenRouter key, or use your Claude plan through Claude Code, so it can write replies."))
            } else if config.provider == .claudeCode, let problem = claudeStatus?.problem {
                out.append(AppNotice(id: "key", kind: .warning, title: "Claude Code needs attention", message: problem))
            }
            if automation == -1743 {
                out.append(AppNotice(id: "automation-denied", kind: .error, title: "Sending is blocked",
                                     message: "macOS won't let iMessager control Messages, so replies can't go out. Turn on Messages under iMessager in Privacy & Security › Automation."))
            } else if automation == -1744, enabledCount > 0 || config.greeter.enabled {
                out.append(AppNotice(id: "automation-ask", kind: .info, title: "Allow sending through Messages",
                                     message: "macOS will ask once before the first reply goes out. Do it now so no reply gets stuck waiting."))
            }
            if contactsStatus == .denied {
                out.append(AppNotice(id: "contacts-denied", kind: .warning, title: "Contacts access is off",
                                     message: "Chats show numbers instead of names, and the new-contact greeter can't tell who's new."))
            }
        }
        return out.filter { !dismissedNotices.contains($0.id) } + transientNotices
    }

    func dismissNotice(_ id: String) {
        transientNotices.removeAll { $0.id == id }
        dismissedNotices.insert(id)
    }

    /// Checks everything chat.db reading and sending depend on. Cheap: one open() and one TCC query.
    func checkHealth(initial: Bool = false) async {
        let previous = dbAccess
        let access = await db.probe()
        let automationStatus = await Task.detached { MessageSender.automationStatus(ask: false) }.value
        dbAccess = access
        automation = automationStatus
        contactsStatus = ContactsIndex.status
        lastHealthCheck = Date()

        if access == .ok, previous != .ok {
            await startAgent()
            if previous != .checking {
                flash(AppNotice(id: "fda-ok", kind: .success, title: "Full Disk Access is on",
                                message: "Reading \(chats.count) conversations from chat.db."))
            }
        }
        if initial, access != .ok { showChecklist = true }
    }

    /// Every 2 s while something is blocked (so flipping a switch in System Settings shows up right away), else every 30 s.
    func startHealthLoop() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                let urgent = self.map { $0.dbAccess != .ok || $0.automation == -1743 } ?? false
                try? await Task.sleep(for: .seconds(urgent ? 2 : 30))
                await self?.checkHealth()
            }
        }
    }

    func requestAutomation() async {
        _ = await Task.detached { MessageSender.automationStatus(ask: true) }.value
        await checkHealth()
    }

    var automationText: String {
        switch automation {
        case .some(0): "Allowed"
        case .some(-1743): "Blocked. Turn on Messages under iMessager in Privacy & Security › Automation."
        case .some(-1744): "Not asked yet. macOS asks before the first reply; click Allow to do it now."
        case .some(-600): "Messages isn't open, so this can't be checked yet. It opens by itself when a reply goes out."
        case .some(let status): "Unknown (\(status))"
        case .none: "Checking…"
        }
    }

    func openMessages() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Messages.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// True when launched as the raw binary (e.g. from Terminal), where macOS grants permissions to the terminal instead.
    var runningOutsideBundle: Bool { !Bundle.main.bundlePath.hasSuffix(".app") }

    private func flash(_ notice: AppNotice, seconds: Double = 5) {
        transientNotices.removeAll { $0.id == notice.id }
        transientNotices.append(notice)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.transientNotices.removeAll { $0.id == notice.id }
        }
    }
}
