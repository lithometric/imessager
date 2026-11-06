import AppKit
import SwiftUI

struct IntegrationsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Page {
            PageIntro("Context the AI can use when it replies. Small local sources go straight into the prompt (no extra round trip); bigger ones become tools it calls only when needed.") {
                Menu {
                    Section("Quick add") {
                        ForEach(IntegrationPreset.allCases) { preset in
                            Button { state.addPreset(preset) } label: { Label(preset.title, systemImage: preset.icon) }
                        }
                    }
                    Section("Any source") {
                        ForEach(IntegrationKind.allCases) { kind in
                            Button { state.addIntegration(kind) } label: { Label(kind.title, systemImage: kind.icon) }
                        }
                    }
                } label: {
                    Label("Add Integration", systemImage: "plus")
                }
                .menuStyle(.button)
                .glassButtonStyle(prominent: true)
                .fixedSize()
            }
        } content: {
            VStack(spacing: 12) {
                ForEach($state.config.integrations) { $item in
                    IntegrationCard(item: $item)
                }
            }
            Label("Tools can be triggered by what people text you. Only connect tools that are safe to run for the contacts you've switched on. The new-contact greeter never gets tools.",
                  systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct IntegrationCard: View {
    @Environment(AppState.self) private var state
    @Binding var item: IntegrationConfig
    @State private var output: String?
    @State private var testing = false

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(14)
                if item.enabled {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        fields
                        footer
                    }
                    .padding(14)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: item.enabled)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $item.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                Text(item.kind.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if item.enabled, let status = state.integrationStatus[item.id] {
                Text(status)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            Toggle("Enabled", isOn: $item.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
            Menu {
                Button("Test") { Task { await test() } }
                if item.kind == .mcp || item.kind == .remoteMCP {
                    Button(item.kind == .mcp ? "Restart server" : "Reconnect") { Task { await state.restartIntegration(item.id) } }
                }
                Divider()
                Button("Remove", role: .destructive) {
                    let id = item.id
                    DispatchQueue.main.async { state.removeIntegration(id) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await test() }
                } label: {
                    Label("Test", systemImage: "play.fill")
                }
                .glassButtonStyle()
                .controlSize(.small)
                if testing { ProgressView().controlSize(.small) }
                if output != nil {
                    Button("Hide") { output = nil }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
            }
            if let output {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch item.kind {
        case .profile:
            Editor(title: "About you", text: $item.notes,
                   placeholder: "Your name, what you do, where you live, how you text, who's who, standing plans the AI should know…")
        case .calendar:
            Text("Reads every calendar in the macOS Calendar app, Google Calendar included once your Google account is added in System Settings › Internet Accounts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("Include the next \(item.days) day\(item.days == 1 ? "" : "s") of events in every prompt", value: $item.days, in: 0...14)
                .font(.callout)
            HStack(spacing: 8) {
                Label(CalendarIntegration.authorized ? "Calendar access granted" : "Calendar access needed",
                      systemImage: CalendarIntegration.authorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(CalendarIntegration.authorized ? .green : .orange)
                if !CalendarIntegration.authorized {
                    Button("Grant access") { Task { await state.requestCalendarAccess() } }.controlSize(.small)
                    Button("Open Settings") { state.openPrivacyPane("Privacy_Calendars") }.controlSize(.small)
                }
            }
        case .contacts:
            Text("Adds a lookup_contact tool for names, birthdays, companies and cities.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .folder:
            Field("Folder") {
                HStack {
                    TextField("Folder", text: $item.path, prompt: Text("~/Documents/Notes"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder() }
                }
            }
        case .webhook:
            Field("When should the AI call it?") {
                TextField("Description", text: $item.notes, prompt: Text("Look up a customer's order status by name or order number"))
                    .textFieldStyle(.roundedBorder)
            }
            Field("Endpoint") {
                HStack {
                    Picker("Method", selection: $item.method) {
                        Text("POST").tag("POST")
                        Text("GET").tag("GET")
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("URL", text: $item.url, prompt: Text("https://hooks.example.com/lookup"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("The AI sends {\"query\": \"…\"} (POST) or ?query=… (GET). The response text goes back to the model.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Editor(title: "Headers, one per line", text: $item.headers, placeholder: "Authorization: Bearer …", mono: true)
        case .mcp:
            Field("Launch command") {
                TextField("Command", text: $item.command, prompt: Text("npx -y @modelcontextprotocol/server-memory"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
            Editor(title: "Environment, one KEY=value per line", text: $item.env, placeholder: "GITHUB_PERSONAL_ACCESS_TOKEN=…", mono: true)
        case .remoteMCP:
            let isGitHub = (URL(string: item.url)?.host() ?? "").contains("github")
            if isGitHub {
                Text("GitHub doesn't offer browser sign-in to other apps. Use your GitHub CLI login, or paste a personal access token as “Authorization: Bearer …”. Read-only by default (X-MCP-Readonly), since replies are triggered by other people's texts.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !item.notes.isEmpty {
                Text(item.notes).font(.caption).foregroundStyle(.secondary)
            }
            Field("Server URL") {
                TextField("URL", text: $item.url, prompt: Text("https://mcp.example.com/mcp"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
            HStack(spacing: 10) {
                if let tokens = MCPAuth.tokens(for: item.id) {
                    Label(tokens.clientID == MCPAuth.githubCLIClient ? "Using your GitHub CLI login" : "Signed in with your browser",
                          systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Button("Sign Out") { state.signOutMCP(item.id) }
                        .glassButtonStyle()
                } else if (URL(string: item.url)?.host() ?? "").contains("github") {
                    if MCPAuth.githubCLI != nil {
                        Button { state.useGitHubCLI(item.id) } label: { Label("Use GitHub CLI Login", systemImage: "terminal") }
                            .glassButtonStyle(prominent: true)
                    }
                    Button("Create a Token…") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    }
                    .glassButtonStyle()
                } else {
                    Button { state.signInMCP(item.id) } label: { Label("Sign In with Browser", systemImage: "person.badge.key") }
                        .glassButtonStyle(prominent: true)
                    Text("For servers that use OAuth (Linear, Notion, Atlassian…)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Editor(title: "Headers, one per line (or a token instead of signing in)", text: $item.headers,
                   placeholder: "Authorization: Bearer …", mono: true)
        case .webSearch:
            Field("Model override") {
                TextField("Model", text: $item.model, prompt: Text("Optional. Defaults to your reply model"))
                    .textFieldStyle(.roundedBorder)
            }
            Text("Runs only when the model asks, through OpenRouter's web plugin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch item.kind {
        case .profile: .indigo
        case .calendar: .red
        case .contacts: .gray
        case .folder: .blue
        case .webhook: .teal
        case .mcp: .purple
        case .remoteMCP: .indigo
        case .webSearch: .green
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        output = await state.describeIntegration(item.id)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            item.path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Caption label above a control.
struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct Editor: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var mono = false

    var body: some View {
        Field(title) {
            TextEditor(text: $text)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 160)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}
