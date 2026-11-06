import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var keyStatus = ""
    @State private var verifying = false
    @State private var showModels = false
    @State private var claudeTest = ""
    @State private var testingClaude = false

    /// Spam and spending guards, with defaults that are safe to leave alone.
    private var limitsSection: some View {
        @Bindable var state = state
        let limits = state.config.limits
        let today = state.config.stats.day == Date.now.formatted(.iso8601.year().month().day())
        return Section {
            LabeledContent("Replies per chat") {
                Stepper("\(state.config.maxRepliesPerHour) per hour", value: $state.config.maxRepliesPerHour, in: 1...120)
            }
            LabeledContent("Replies per group chat") {
                Stepper("\(limits.groupRepliesPerHour) per hour", value: $state.config.limits.groupRepliesPerHour, in: 1...60)
            }
            LabeledContent("Time between replies in a chat") {
                Stepper(limits.secondsBetweenReplies > 0 ? "\(Int(limits.secondsBetweenReplies)) sec" : "None",
                        value: $state.config.limits.secondsBetweenReplies, in: 0...600, step: 10)
            }
            LabeledContent("Replies across all chats") {
                Stepper("\(limits.repliesPerHourAllChats) per hour", value: $state.config.limits.repliesPerHourAllChats, in: 5...500, step: 5)
            }
            LabeledContent("Automatic AI calls per day") {
                Stepper("\(limits.autoCallsPerDay)", value: $state.config.limits.autoCallsPerDay, in: 25...5000, step: 25)
            }
            if state.config.provider == .openRouter {
                LabeledContent("OpenRouter spend per day") {
                    Stepper(limits.dailySpendUSD > 0 ? String(format: "$%.2f", limits.dailySpendUSD) : "No limit",
                            value: $state.config.limits.dailySpendUSD, in: 0...100, step: 0.5)
                }
            }
            LabeledContent("Spam guard") {
                HStack(spacing: 14) {
                    Stepper("\(limits.floodTexts) texts", value: $state.config.limits.floodTexts, in: 3...100)
                    Stepper("in \(Int(limits.floodMinutes)) min", value: $state.config.limits.floodMinutes, in: 1...30)
                }
            }
            LabeledContent("Then pause auto-reply in that chat for") {
                Stepper("\(Int(limits.blockMinutes)) min", value: $state.config.limits.blockMinutes, in: 5...1440, step: 5)
            }
            HStack {
                Text("Today: \(today ? state.config.stats.autoCallsToday : 0) automatic AI calls"
                     + (state.config.provider == .openRouter ? String(format: " · $%.2f", today ? state.config.stats.spentToday : 0) : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") {
                    state.config.limits = .defaults
                    state.config.maxRepliesPerHour = AppConfig().maxRepliesPerHour
                }
                .disabled(limits == .defaults && state.config.maxRepliesPerHour == AppConfig().maxRepliesPerHour)
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("Keeps someone spamming you, or a very busy group, from using up your AI. Only automatic replies, greetings, summaries and the scheduled recap count; anything you start yourself always runs.")
                .font(.caption)
        }
        .monospacedDigit()
    }

    static func hourName(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        @Bindable var state = state
        GeometryReader { geo in
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $state.config.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Transparency") {
                        HStack(spacing: 10) {
                            Text("Solid").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $state.config.transparency, in: 0...1)
                                .frame(width: 200)
                            Text("Clear").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $state.config.hideAutomated) {
                        Text("Keep transactions and promotions out of Messages")
                        Text("Payment alerts, codes and texts with “reply STOP” go to their own filters. Right-click a chat to move it.")
                    }
                }

                Section {
                    Picker("Replies written by", selection: $state.config.provider) {
                        Text("OpenRouter").tag(AIProvider.openRouter)
                        Text("Claude plan (Claude Code)").tag(AIProvider.claudeCode)
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: $state.config.autoReplyEveryone) {
                        Text("Auto-reply for everyone")
                        Text("The AI answers every person you text (in your Contacts or someone you've texted before). New numbers, codes and promotions stay off. Switch any chat off from its button at the top right.")
                    }
                    Toggle(isOn: $state.config.autoReplyGroups) {
                        Text("Auto-reply in every group chat")
                        Text("The AI joins in when someone talks to you or a reply is clearly natural, and otherwise stays quiet. At most \(state.config.limits.groupRepliesPerHour) replies per group an hour (Limits below). Switch any group off from its button at the top right.")
                    }
                    Toggle(isOn: $state.config.summarizeUnread) {
                        Text("Summarize unread conversations")
                        Text("A one-line summary in the list when several texts are waiting. Sends those unread texts to the AI above.")
                    }
                    Toggle(isOn: $state.config.recap.enabled) {
                        Text("Daily recap on Home")
                        Text("Once a day, a few lines about your texts and a checklist of what you said you'd do. Sends the last day of texts in your main list to the AI above.")
                    }
                    if state.config.recap.enabled {
                        Picker(selection: $state.config.recap.onCheck) {
                            Text("Write a reply for me to send").tag(TodoAction.draft)
                            Text("Send a reply automatically").tag(TodoAction.send)
                            Text("Just check it off").tag(TodoAction.nothing)
                        } label: {
                            Text("Checking off a to-do")
                            Text(state.config.recap.onCheck == .send
                                 ? "The AI writes the follow-up and sends it in the background. You can still undo it for \(Int(state.config.undoSendSeconds))s from the conversation."
                                 : "Opens the conversation with a follow-up written in the message box, ready for you to send.")
                        }
                        Picker("Write it at", selection: $state.config.recap.hour) {
                            Section("Morning (covers yesterday)") {
                                ForEach([6, 7, 8, 9, 10], id: \.self) { Text(Self.hourName($0)).tag($0) }
                            }
                            Section("Night (covers today)") {
                                ForEach([18, 20, 21, 22, 23], id: \.self) { Text(Self.hourName($0)).tag($0) }
                            }
                        }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text(state.config.provider == .claudeCode
                         ? "Uses your Claude Pro or Max plan the way Anthropic supports it: iMessager runs your own Claude Code for each reply, and Claude Code signs in for itself. iMessager never sees or stores your Claude login."
                         : "Any model on OpenRouter, billed to your OpenRouter credits.")
                        .font(.caption)
                }

                if state.config.provider == .claudeCode {
                    claudeSection
                } else {
                Section {
                    SecureField("API key", text: $state.apiKey, prompt: Text("sk-or-v1-…"))
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            if verifying { ProgressView().controlSize(.small) }
                            Text(keyStatus.isEmpty ? (state.apiKey.trimmed.isEmpty ? "No key yet" : "Not checked") : keyStatus)
                                .foregroundStyle(.secondary)
                            Button("Verify") {
                                Task {
                                    verifying = true
                                    keyStatus = await state.verifyKey()
                                    verifying = false
                                }
                            }
                            .disabled(state.apiKey.trimmed.isEmpty || verifying)
                        }
                    }
                    LabeledContent("Model") {
                        HStack(spacing: 8) {
                            TextField("Model", text: $state.config.model)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: 260)
                            Menu("Presets") {
                                ForEach(AppConfig.quickModels, id: \.id) { m in
                                    Button(m.label) { state.config.model = m.id }
                                }
                            }
                            .fixedSize()
                            Button("Browse…") { showModels = true }
                        }
                    }
                    Toggle("Route to the lowest-latency provider", isOn: $state.config.fastRouting)
                } header: {
                    Text("OpenRouter")
                } footer: {
                    Link("Get an OpenRouter key", destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.caption)
                }
                }

                Section {
                    TextEditor(text: $state.config.persona)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 170)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                    HStack {
                        Text("Per-contact instructions, your integrations and the recent conversation are added automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Default") { state.config.persona = AppConfig.defaultPersona }
                            .disabled(state.config.persona == AppConfig.defaultPersona)
                    }
                } header: {
                    Text("Voice & Rules")
                }

                Section("Behavior") {
                    LabeledContent("Wait before replying") {
                        HStack(spacing: 10) {
                            Slider(value: $state.config.replyDelay, in: 0...20, step: 0.5)
                                .frame(width: 200)
                            Text("\(state.config.replyDelay, specifier: "%.1f") s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    LabeledContent("History in each prompt") {
                        Stepper("\(state.config.historyLimit) messages", value: $state.config.historyLimit, in: 5...150, step: 5)
                            .monospacedDigit()
                    }
                    LabeledContent("Pause after you reply yourself") {
                        Stepper("\(Int(state.config.pauseAfterManualMinutes)) min", value: $state.config.pauseAfterManualMinutes, in: 0...240, step: 5)
                            .monospacedDigit()
                    }
                    LabeledContent("Undo send") {
                        Stepper(state.config.undoSendSeconds > 0 ? "\(Int(state.config.undoSendSeconds)) sec" : "Off",
                                value: $state.config.undoSendSeconds, in: 0...30, step: 1)
                            .monospacedDigit()
                    }
                    Toggle(isOn: $state.config.holdAIReplies) {
                        Text("Hold AI replies for the undo window too")
                        Text("A few seconds to stop an AI reply before it goes out. Off is faster.")
                    }
                    .disabled(state.config.undoSendSeconds == 0)
                    Toggle(isOn: $state.config.dryRun) {
                        Text("Dry run")
                        Text("Draft replies in Activity but never send them")
                    }
                }

                limitsSection

                Section {
                    Toggle(isOn: $state.config.greeter.enabled) {
                        Text("Greet new people who introduce themselves")
                        Text("e.g. “hey it's Sarah from the gym” → “Great to meet you, Sarah!”")
                    }
                    Group {
                        LabeledContent("How to greet them") {
                            TextField("Greeting style", text: $state.config.greeter.instructions, axis: .vertical)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...3)
                                .frame(maxWidth: 320)
                        }
                        Toggle("Save them to Contacts", isOn: $state.config.greeter.saveToContacts)
                        Toggle("Then turn on auto-reply for them", isOn: $state.config.greeter.enableAutoReply)
                    }
                    .disabled(!state.config.greeter.enabled)
                } header: {
                    Text("New Contacts")
                } footer: {
                    Text("Only for numbers that aren't in your Contacts and have never heard from you. Spam, codes and texts without a name are ignored.")
                        .font(.caption)
                }

                Section {
                    if state.notificationsAllowed == false {
                        HStack {
                            Label("Notifications are off for iMessager in System Settings", systemImage: "bell.slash.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Allow…") { Notifier.shared.requestPermission() }
                            Button("Open Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                        }
                    }
                    Toggle(isOn: $state.config.notifications.incoming) {
                        Text("New messages")
                        Text("Like Messages: sender, text and their photo, with Reply, Reply with \(state.config.provider == .claudeCode ? "Claude" : "AI") (works even when auto-reply is off) and Mark as Read. Muted conversations, transactions and promotions stay quiet.")
                    }
                    Toggle("Show message previews", isOn: $state.config.notifications.previews)
                        .disabled(!state.config.notifications.incoming)
                    LabeledContent("Messages' own notifications") {
                        Button("Turn Off in System Settings…") { state.openMessagesNotificationSettings() }
                    }
                    Toggle(isOn: $state.config.syncReadWithMessages) {
                        Text("Sync read status with Messages")
                        Text(MessagesSync.allowed
                             ? "Reading a chat here marks it read in Messages and on your devices (read receipts go out if you send them)."
                             : "Needs Accessibility permission for iMessager.")
                    }
                    if state.config.syncReadWithMessages && !MessagesSync.allowed {
                        HStack {
                            Button("Allow Accessibility…") { MessagesSync.requestPermission() }
                            Button("Open Settings") { state.openPrivacyPane("Privacy_Accessibility") }
                        }
                    }
                    Toggle(isOn: $state.config.notifications.aiReplies) {
                        Text("When the AI replies for you")
                        Text("Only while iMessager isn't the app in front. The reply waits a moment first, with Undo in the notification.")
                    }
                    if state.config.notifications.aiReplies {
                        LabeledContent("Time to undo from the notification") {
                            Stepper(state.config.aiUndoSeconds > 0 ? "\(Int(state.config.aiUndoSeconds)) sec" : "Off",
                                    value: $state.config.aiUndoSeconds, in: 0...60, step: 5)
                                .monospacedDigit()
                        }
                    }
                    Toggle("When a new contact is greeted", isOn: $state.config.notifications.greetings)
                    Toggle("When a text couldn't be sent", isOn: $state.config.notifications.failures)
                    Toggle("Dry-run drafts", isOn: $state.config.notifications.drafts)
                    Button("Notification Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Messages notifies too, so you may want to turn its notifications off (System Settings › Notifications › Messages) to get each text once.")
                        .font(.caption)
                }

                Section("Permissions") {
                    PermissionRow(title: "Full Disk Access", detail: diskDetail, granted: state.hasDiskAccess) {
                        Button("Open Settings") { state.openPrivacyPane("Privacy_AllFiles") }
                    }
                    PermissionRow(title: "Contacts", detail: "Names, spotting new numbers, saving new contacts", granted: state.contactsAccess) {
                        if state.contactsStatus == .notDetermined {
                            Button("Allow") { Task { await state.requestContactsAccess() } }
                        } else if !state.contactsAccess {
                            Button("Open Settings") { state.openPrivacyPane("Privacy_Contacts") }
                        }
                    }
                    PermissionRow(title: "Control Messages", detail: state.automationText, granted: state.automation == 0) {
                        if state.automation == -1744 {
                            Button("Allow") { Task { await state.requestAutomation() } }
                        } else if state.automation == -1743 {
                            Button("Open Settings") { state.openPrivacyPane("Privacy_Automation") }
                        }
                    }
                    HStack {
                        Button("Open Setup Checklist") { state.showChecklist = true }
                        Spacer()
                        Button("Relaunch iMessager") { state.relaunch() }
                    }
                }

                Section {
                    LabeledContent("Messages") {
                        Text("~/Library/Messages/chat.db (read-only)").foregroundStyle(.secondary)
                    }
                    LabeledContent("Settings") {
                        Button("Show config.json in Finder") {
                            state.saveNow()
                            NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.file])
                        }
                    }
                    LabeledContent("API key") {
                        Text("Keychain").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("iMessager keeps no database of its own. The activity log lives in memory.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .contentMargins(.horizontal, max(0, (geo.size.width - Theme.contentMaxWidth) / 2), for: .scrollContent)

        }
        .task { state.notificationsAllowed = await Notifier.shared.allowed() }
        .sheet(isPresented: $showModels) {
            ModelBrowser(selection: $state.config.model).environment(state)
        }
    }

    // MARK: Claude plan

    @ViewBuilder private var claudeSection: some View {
        @Bindable var state = state
        let status = state.claudeStatus
        Section {
            LabeledContent("Claude Code") {
                HStack(spacing: 8) {
                    if status == nil { ProgressView().controlSize(.small) }
                    Label(claudeSummary(status), systemImage: status?.ready == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(status?.ready == true ? Color.green : (status == nil ? Color.secondary : Color.orange))
                        .lineLimit(1)
                    Button("Check Again") { Task { await state.refreshClaudeStatus() } }
                }
            }
            if let problem = status?.problem {
                HStack(alignment: .top, spacing: 8) {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if status?.path == nil {
                        Link("Get Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
                    } else {
                        Button("Open Terminal") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                        }
                    }
                }
            }
            LabeledContent("Model") {
                Picker("Model", selection: $state.config.claudeCodeModel) {
                    ForEach(ClaudeCode.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
            LabeledContent("Try it") {
                HStack(spacing: 8) {
                    if testingClaude { ProgressView().controlSize(.small) }
                    Text(claudeTest.isEmpty ? "Sends a sample text through Claude Code" : claudeTest)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Test") { Task { await testClaude() } }
                        .disabled(testingClaude || status?.ready != true)
                }
            }
            LabeledContent("Claude Code location") {
                TextField("Location", text: $state.config.claudeCodePath, prompt: Text(status?.path ?? "Found automatically"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 300)
            }
        } header: {
            Text("Claude Plan")
        } footer: {
            Text("For safety, Claude Code runs with all of its tools, MCP servers, hooks and settings switched off, in an empty folder, so a text can't make it read files or run commands on your Mac. That also means replies come from the conversation and your integrations' context; tools (calendar search, resending failed texts, extra messages) need OpenRouter. Replies count toward your Claude plan's usage limits.")
                .font(.caption)
        }
        .task { if state.claudeStatus == nil { await state.refreshClaudeStatus() } }
    }

    private func claudeSummary(_ status: ClaudeCode.Status?) -> String {
        guard let status else { return "Checking…" }
        guard status.path != nil else { return "Not installed" }
        let version = status.version.map { "v\($0)" }
        let plan = status.plan.map { "\($0.capitalized) plan" }
        return ([status.loggedIn ? "Signed in" : "Not signed in", plan, version].compactMap { $0 }).joined(separator: " · ")
    }

    private func testClaude() async {
        testingClaude = true
        defer { testingClaude = false }
        do {
            let reply = try await state.claude.complete(
                system: "You text on someone's behalf. Reply with one short, casual text and nothing else.",
                prompt: "Maya: are we still on for climbing tomorrow?",
                model: state.config.claudeCodeModel, customPath: state.config.claudeCodePath)
            claudeTest = "“\(reply.text.trimmed)” · \(reply.ms) ms"
        } catch {
            claudeTest = error.localizedDescription
        }
    }

    private var diskDetail: String {
        switch state.dbAccess {
        case .ok: "Reading ~/Library/Messages/chat.db"
        case .checking: "Checking…"
        case .noPermission: "Blocked by macOS. Turn it on for iMessager."
        case .missing: "No chat.db yet. Sign in to Messages first."
        case .failed(let reason): reason
        }
    }
}

private struct PermissionRow<Actions: View>: View {
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack { actions() }.controlSize(.small)
        }
    }
}

private struct ModelBrowser: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var query = ""
    @State private var toolsOnly = true

    private var filtered: [ORModel] {
        state.models.filter { m in
            (!toolsOnly || m.tools) &&
                (query.isEmpty || m.id.localizedCaseInsensitiveContains(query) || m.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search \(state.models.count) models", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Supports tools", isOn: $toolsOnly).toggleStyle(.checkbox)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            List(filtered) { m in
                Button {
                    selection = m.id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name)
                            Text(m.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(m.priceLabel).font(.caption).foregroundStyle(.secondary)
                        if m.id == selection { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if state.models.isEmpty { ProgressView("Loading models…") }
            }
        }
        .frame(width: 620, height: 540)
        .task { if state.models.isEmpty { await state.loadModels() } }
    }
}
