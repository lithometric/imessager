import SwiftUI

/// Floating notification cards in the window's top-right corner.
struct NoticeStack: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(state.notices) { notice in
                NoticeCard(notice: notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(14)
        .animation(.spring(duration: 0.35), value: state.notices.map(\.id))
    }
}

private struct NoticeCard: View {
    @Environment(AppState.self) private var state
    let notice: AppNotice

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notice.kind.icon)
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(notice.kind.tint.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(.headline)
                Text(notice.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if notice.kind != .success {
                    HStack(spacing: 8) { actions }
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if notice.dismissible {
                Button {
                    state.dismissNotice(notice.id)
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 390, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: notice.kind.tint.opacity(0.08))
    }

    @ViewBuilder private var actions: some View {
        switch notice.id {
        case "fda":
            Button("Open Full Disk Access") { state.openPrivacyPane("Privacy_AllFiles") }
                .glassButtonStyle(prominent: true)
            Button("Show me how") { state.showChecklist = true }
                .glassButtonStyle()
        case "db-missing":
            Button("Open Messages") { state.openMessages() }
                .glassButtonStyle(prominent: true)
            Button("Show me how") { state.showChecklist = true }
                .glassButtonStyle()
        case "db-error":
            Button("Relaunch") { state.relaunch() }
                .glassButtonStyle(prominent: true)
            Button("Details") { state.showChecklist = true }
                .glassButtonStyle()
        case "key":
            Button("Add key") { state.modal = .settings }
                .glassButtonStyle(prominent: true)
        case "automation-denied":
            Button("Open Automation settings") { state.openPrivacyPane("Privacy_Automation") }
                .glassButtonStyle(prominent: true)
        case "automation-ask":
            Button("Allow") { Task { await state.requestAutomation() } }
                .glassButtonStyle(prominent: true)
        case "messages-notifications":
            Button("Open Messages Notifications") { state.openMessagesNotificationSettings() }
                .glassButtonStyle(prominent: true)
        case "contacts-denied":
            Button("Open Contacts settings") { state.openPrivacyPane("Privacy_Contacts") }
                .glassButtonStyle()
        default:
            EmptyView()
        }
    }
}

private extension AppNotice.Kind {
    var icon: String {
        switch self {
        case .error: "lock.fill"
        case .warning: "exclamationmark"
        case .info: "info"
        case .success: "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        case .success: .green
        }
    }
}

/// Live checklist of everything iMessager needs, with the exact fix for each item.
struct SetupChecklist: View {
    @Environment(AppState.self) private var state
    @State private var checking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // The app icon, with a small status badge.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: state.needsSetup ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white, state.needsSetup ? Color.orange : Color.green)
                            .offset(x: 2, y: 2)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.needsSetup ? "Finish setting up iMessager" : "All set").font(.title2.bold())
                    Text(state.needsSetup
                         ? "It needs a few permissions to read chat.db and send replies. This page checks live, so you can leave it open while you fix things."
                         : "iMessager can read your messages and send replies.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    databaseRow
                    sendRow
                    keyRow
                    contactsRow
                    readSyncRow
                    messagesNotificationsRow
                }
                .padding(20)
            }

            Divider()
            HStack {
                if let last = state.lastHealthCheck {
                    Text("Checked \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button {
                    Task {
                        checking = true
                        await state.checkHealth()
                        checking = false
                    }
                } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(checking)
                Spacer()
                Button("Done") { state.modal = nil }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(prominent: true)
            }
            .padding(16)
        }

    }

    // MARK: Rows

    private var databaseRow: some View {
        let status: CheckStatus = switch state.dbAccess {
        case .ok: .ok
        case .checking: .checking
        case .missing: .warning
        case .noPermission, .failed: .missing
        }
        return CheckRow(title: "Read your messages (chat.db)", required: true, status: status) {
            switch state.dbAccess {
            case .ok:
                Text("Reading ~/Library/Messages/chat.db, read-only.")
            case .checking:
                Text("Checking access to ~/Library/Messages/chat.db…")
            case .noPermission:
                Text("macOS blocks every app from Messages' database until you give it Full Disk Access.")
                Steps([
                    "Click Open Full Disk Access.",
                    "Click + and choose iMessager, or drag it into the list from Finder.",
                    "Switch it on. This row turns green within a couple of seconds.",
                ])
                Text("Grant it to this copy of the app:").font(.caption).foregroundStyle(.secondary)
                Text(Bundle.main.bundlePath).font(.caption.monospaced()).textSelection(.enabled)
                Text("Already switched on but still blocked? macOS ties the switch to one specific build. Select iMessager, remove it with −, add it again, then Relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
                if state.runningOutsideBundle {
                    Text("You launched the raw binary, so macOS is asking on behalf of your terminal. Open iMessager.app instead.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Open Full Disk Access") { state.openPrivacyPane("Privacy_AllFiles") }.buttonStyle(.borderedProminent)
                    Button("Show iMessager in Finder") { state.revealApp() }
                    Button("Relaunch") { state.relaunch() }
                }
            case .missing:
                Text("There's no chat.db on this Mac yet. Messages creates it once you're signed in.")
                Steps([
                    "Open Messages.",
                    "Sign in with your Apple ID under Messages › Settings › iMessage.",
                    "Send or receive one message.",
                ])
                Button("Open Messages") { state.openMessages() }.buttonStyle(.borderedProminent)
            case .failed(let reason):
                Text("chat.db is there and readable, but SQLite couldn't use it: \(reason).")
                Text("Relaunch iMessager. If it keeps happening, quit Messages and try again.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Relaunch") { state.relaunch() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var sendRow: some View {
        let status: CheckStatus = switch state.automation {
        case .some(0): .ok
        case .some(-1743): .missing
        case .none: .checking
        default: .warning
        }
        return CheckRow(title: "Send through Messages", required: true, status: status) {
            Text(state.automationText)
            switch state.automation {
            case .some(-1743):
                Button("Open Automation settings") { state.openPrivacyPane("Privacy_Automation") }.buttonStyle(.borderedProminent)
            case .some(-1744):
                Button("Allow") { Task { await state.requestAutomation() } }.buttonStyle(.borderedProminent)
            case .some(-600):
                Button("Open Messages") { state.openMessages() }
            default:
                EmptyView()
            }
        }
    }

    private var keyRow: some View {
        let hasKey = state.aiReady
        let claude = state.config.provider == .claudeCode
        return CheckRow(title: claude ? "Claude plan (Claude Code)" : "OpenRouter API key", required: true, status: hasKey ? .ok : .missing) {
            Text(hasKey ? (claude ? "Replies use your Claude plan through Claude Code." : "Saved in your Keychain.")
                 : (claude ? (state.claudeStatus?.problem ?? "Checking Claude Code…") : "Needed to write replies."))
            if !hasKey {
                Button("Add key in Settings") {
                    state.modal = .settings
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var readSyncRow: some View {
        CheckRow(title: "Read status in Messages", required: false, status: MessagesSync.allowed ? .ok : .warning) {
            Text(MessagesSync.allowed
                 ? "Reading a conversation here marks it read in Messages and on your devices too."
                 : "Allow Accessibility so reading a conversation here also marks it read in Messages (and on your iPhone).")
            if !MessagesSync.allowed {
                HStack {
                    Button("Allow…") { MessagesSync.requestPermission() }.buttonStyle(.borderedProminent)
                    Button("Open Settings") { state.openPrivacyPane("Privacy_Accessibility") }
                }
            }
        }
    }

    private var messagesNotificationsRow: some View {
        CheckRow(title: "Messages' own notifications", required: false,
                 status: state.config.seenTips.contains("messages-notifications") ? .ok : .warning) {
            Text("iMessager notifies you about new texts. Turn Messages' notifications off so each text only shows once. macOS doesn't let apps change this for another app, so it's one switch in System Settings.")
            Button("Open Messages Notifications") { state.openMessagesNotificationSettings() }
        }
    }

    private var contactsRow: some View {
        let status: CheckStatus = switch state.contactsStatus {
        case .authorized: .ok
        case .notDetermined: .warning
        default: .missing
        }
        return CheckRow(title: "Contacts", required: false, status: status) {
            Text(state.contactsAccess
                 ? "Names show up and the greeter can spot new numbers."
                 : "Without it, chats show numbers and the new-contact greeter can't tell who's new.")
            if !state.contactsAccess {
                HStack {
                    if state.contactsStatus == .notDetermined {
                        Button("Allow") { Task { await state.requestContactsAccess() } }.buttonStyle(.borderedProminent)
                    }
                    Button("Open Contacts settings") { state.openPrivacyPane("Privacy_Contacts") }
                }
            }
        }
    }
}

private enum CheckStatus { case ok, missing, warning, checking }

private struct CheckRow<Content: View>: View {

    let title: String
    let required: Bool
    let status: CheckStatus
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch status {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .warning: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .checking: ProgressView().controlSize(.small)
                }
            }
            .font(.title2)
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(required ? "Required" : "Recommended")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((required ? Color.red : Color.secondary).opacity(0.12), in: Capsule())
                        .foregroundStyle(required ? Color.red : Color.secondary)
                }
                content()
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(status == .ok ? Color.green.opacity(0.35) : Color(nsColor: .separatorColor)))
    }
}

private struct Steps: View {
    let items: [String]

    init(_ items: [String]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Color.accentColor, in: Circle())
                    Text(item)
                }
            }
        }
    }
}
