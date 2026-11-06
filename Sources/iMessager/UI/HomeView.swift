import Charts
import SwiftUI

/// What iMessager and the AI have been doing, at a glance. Opens by default, and from the Home button.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @State private var stats: ChatDB.MessageStats?
    @State private var range = 30
    @State private var hovered: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if state.config.recap.enabled { RecapCard() }
                if let stats {
                    tiles(stats)
                    chart(stats)
                } else {
                    loading
                }
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .task(id: "\(range)-\(state.revision / 20)") {
            // Re-read every so often as chat.db changes; cheap, but no need on every receipt.
            if let fresh = try? await state.db.stats(days: range) { stats = fresh }
        }
        .task { await state.refreshCredits() }
        .task { state.recapIfDue() }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var state = state
        let status = state.agentStatus
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                BrandLockup(height: 18)
                    .padding(.bottom, 8)
                Text("Overview").font(.system(size: 28, weight: .bold))
                Text("AI totals since \(state.config.stats.since.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(status.color).frame(width: 8, height: 8)
                Text(status.text).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .liquidGlass(in: Capsule())
            Picker("Range", selection: $range) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Tiles

    private func tiles(_ s: ChatDB.MessageStats) -> some View {
        let ai = state.config.stats
        return VStack(alignment: .leading, spacing: 12) {
            Section("Messages · last \(range) days") {
                StatTile(icon: "paperplane.fill", tint: .blue, title: "Sent", value: s.sent.formatted(),
                         note: "\(s.textMessagesSent.formatted()) as text messages")
                StatTile(icon: "tray.and.arrow.down.fill", tint: .orange, title: "Received", value: s.received.formatted(),
                         note: "across \(s.conversations.formatted()) conversations")
                StatTile(icon: "checkmark.circle.fill", tint: .green, title: "Delivered", value: percent(s.delivered, of: s.iMessagesSent),
                         note: "\(s.delivered.formatted()) of \(s.iMessagesSent.formatted()) iMessages")
                StatTile(icon: "eye.fill", tint: .indigo, title: "Open rate", value: percent(s.read, of: s.delivered),
                         note: "read receipts on delivered iMessages")
                StatTile(icon: "exclamationmark.circle.fill", tint: s.failed > 0 ? .red : .gray, title: "Not delivered",
                         value: s.failed.formatted(), note: s.failed > 0 ? "right-click one to try again" : "nothing failed")
                StatTile(icon: "circlebadge.fill", tint: .blue, title: "Unread now", value: state.unreadCount.formatted(),
                         note: "in your main list")
            }
            Section("AI") {
                StatTile(icon: "sparkles", tint: .purple, title: "AI replies sent", value: ai.aiReplies.formatted(),
                         note: "\(ai.greetings.formatted()) new-contact greetings")
                StatTile(icon: "bolt.fill", tint: .green, title: "Auto-reply on", value: state.enabledCount.formatted(),
                         note: "conversations the AI answers")
                StatTile(icon: "timer", tint: .teal, title: "Avg response", value: ai.averageLatencyMs.map { "\($0.formatted()) ms" } ?? "—",
                         note: "from their text to the AI's draft")
                StatTile(icon: "dollarsign.circle.fill", tint: .mint, title: "AI spend", value: money(ai.costUSD),
                         note: "\(ai.calls.formatted()) calls · \(tokens(ai.promptTokens + ai.completionTokens)) tokens")
                if state.config.provider == .claudeCode {
                    StatTile(icon: "sparkle", tint: .orange, title: "Claude plan", value: state.claudeStatus?.plan?.capitalized ?? "Claude",
                             note: "replies included, through Claude Code")
                } else {
                    StatTile(icon: "creditcard.fill", tint: .cyan, title: "OpenRouter credits", value: creditsValue,
                             note: creditsNote)
                }
                StatTile(icon: "exclamationmark.triangle.fill", tint: ai.errors > 0 ? .orange : .gray, title: "Errors",
                         value: ai.errors.formatted(), note: ai.errors > 0 ? "details in Activity" : "all clear")
            }
        }
    }

    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder let content: () -> Content

        init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
            self.title = title
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) { content() }
            }
            .padding(.bottom, 8)
        }
    }

    private var creditsValue: String {
        guard let credits = state.credits else { return state.apiKey.isEmpty ? "No key" : "—" }
        if let limit = credits.limit { return money(max(0, limit - credits.usage)) + " left" }
        return money(credits.usage) + " used"
    }

    private var creditsNote: String {
        guard let credits = state.credits else { return state.apiKey.isEmpty ? "add a key in Settings" : "checking…" }
        if let limit = credits.limit { return "\(money(credits.usage)) of \(money(limit)) used" }
        return credits.monthly.map { "\(money($0)) this month" } ?? "no limit on this key"
    }

    // MARK: Chart

    private func chart(_ s: ChatDB.MessageStats) -> some View {
        let days = Array(s.days.suffix(min(range, 30)))
        let selected = hovered.flatMap { h in days.first { Calendar.current.isDate($0.day, inSameDayAs: h) } }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Texts per day").font(.headline)
                Spacer()
                // Legend: always present for two series; values stay in text colors, the swatch carries identity.
                LegendDot(color: .chartSent, label: "Sent")
                LegendDot(color: .chartReceived, label: "Received")
            }
            Chart {
                ForEach(days) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Texts", d.sent))
                        .position(by: .value("Series", "Sent"))
                        .foregroundStyle(Color.chartSent)
                        .cornerRadius(4)
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Texts", d.received))
                        .position(by: .value("Series", "Received"))
                        .foregroundStyle(Color.chartReceived)
                        .cornerRadius(4)
                }
                if let selected {
                    RuleMark(x: .value("Day", selected.day, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.12))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(selected.day.formatted(.dateTime.weekday(.wide).month().day()))
                                    .font(.caption.weight(.semibold))
                                LegendDot(color: .chartSent, label: "\(selected.sent) sent")
                                LegendDot(color: .chartReceived, label: "\(selected.received) received")
                            }
                            .padding(8)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                }
            }
            .chartXSelection(value: $hovered)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: days.count > 14 ? 5 : 2)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .frame(height: 220)
        }
        .padding(18)
        .modifier(HomeCard(radius: 20))
    }

    // MARK: Loading

    private var loading: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 112)
                    .shimmering()
            }
        }
    }

    // MARK: Formatting

    private func percent(_ part: Int, of whole: Int) -> String {
        whole > 0 ? (Double(part) / Double(whole)).formatted(.percent.precision(.fractionLength(0))) : "—"
    }

    private func money(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(usd < 1 ? 3 : 2)))
    }

    private func tokens(_ n: Int) -> String {
        n >= 1000 ? (Double(n) / 1000).formatted(.number.precision(.fractionLength(1))) + "k" : n.formatted()
    }
}

/// One number, Apple style: tinted icon, label, big value, quiet footnote.
private struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HomeCard(radius: 18))
    }
}

/// The day's texts in a few lines, and a checklist of what you said you'd do. Regenerate any time.
private struct RecapCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let recap = state.config.lastRecap
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.config.recap.hour >= 17 ? "moon.stars.fill" : "sun.horizon.fill")
                    .foregroundStyle(state.config.recap.hour >= 17 ? Color.indigo : Color.orange)
                Text("Daily recap").font(.headline)
                if let recap {
                    Text("· last 24 hours, as of \(recap.made.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await state.makeRecap() }
                } label: {
                    HStack(spacing: 5) {
                        if state.makingRecap {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(state.makingRecap ? "Writing…" : "Regenerate")
                    }
                    .font(.caption.weight(.medium))
                }
                .glassButtonStyle()
                .controlSize(.small)
                .disabled(state.makingRecap || !state.aiReady)
            }
            if let recap {
                Text(recap.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .opacity(state.makingRecap ? 0.5 : 1)
                if !recap.todos.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recap.todos) { todo in TodoRow(todo: todo) }
                    }
                    .padding(.top, 2)
                }
            } else {
                Text(state.makingRecap ? "Reading the last day of texts…"
                     : state.aiReady ? "Your recap is written at \(hourLabel) each day. Click Regenerate for one now."
                     : "Connect Claude or OpenRouter in Settings to get a daily recap.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HomeCard(radius: 18))
        .animation(.easeOut(duration: 0.2), value: recap)
    }

    private var hourLabel: String {
        let date = Calendar.current.date(bySettingHour: state.config.recap.hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

}

/// One thing to do: check it off here; click the words to open that conversation.
private struct TodoRow: View {
    @Environment(AppState.self) private var state
    let todo: Recap.Todo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { withAnimation(.snappy) { state.toggleTodo(todo.id) } } label: {
                Group {
                    if state.followingUp.contains(todo.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(todo.done ? Color.accentColor : Color.secondary)
                    }
                }
                .font(.system(size: 14))
                .frame(width: 16)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if let chat = todo.chat { state.openRequest = chat }
                } label: {
                    Text(todo.text)
                        .font(.callout)
                        .strikethrough(todo.done)
                        .foregroundStyle(todo.done ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(todo.chat == nil)
                if state.followingUp.contains(todo.id) {
                    Text("Writing a reply…").font(.caption).foregroundStyle(.secondary)
                } else if let reply = todo.reply {
                    Text("Replied: \(reply)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .contextMenu {
            if todo.done {
                Button("Mark as Not Done") { state.toggleTodo(todo.id) }
            } else {
                if todo.chat != nil, state.config.recap.onCheck != .nothing {
                    Button("Check Off Without Replying") { withAnimation(.snappy) { state.toggleTodo(todo.id, reply: false) } }
                }
                Button(todo.chat != nil && state.config.recap.onCheck != .nothing ? "Check Off and Reply" : "Check Off") {
                    withAnimation(.snappy) { state.toggleTodo(todo.id) }
                }
            }
            if let chat = todo.chat {
                Divider()
                Button("Open Conversation") { state.openRequest = chat }
            }
        }
    }
}

/// Stat tiles and the chart are content, so they're quiet cards; glass stays on the controls floating above them.
private struct HomeCard: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Color.primary.opacity(0.045), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension Color {
    /// Validated pair (colorblind-safe, both modes): iMessage blue for sent, orange for received.
    static let chartSent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x0A84FF) : NSColor(hex: 0x007AFF)
    })
    static let chartReceived = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0xD9770A) : NSColor(hex: 0xFF9500)
    })
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
