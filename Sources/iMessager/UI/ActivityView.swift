import SwiftUI

struct ActivityView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.activity.isEmpty {
            VStack(spacing: 0) {
                AgentStatusCard().padding(Theme.padding)
                ContentUnavailableView("Nothing yet", systemImage: "waveform.path.ecg",
                                       description: Text("Texts from contacts with auto-reply on, and what the AI did about them, show up here."))
            }

        } else {
            Page {
                AgentStatusCard()
                PageIntro("\(state.activity.count) events this session. A live log of what the agent saw and did, kept in memory only.") {
                    Button("Clear") { state.activity.removeAll() }
                        .glassButtonStyle()
                }
            } content: {
                Card(padding: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.activity.enumerated()), id: \.element.id) { i, event in
                            if i > 0 { Divider().padding(.leading, 52) }
                            ActivityRow(event: event)
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    private var style: (icon: String, color: Color, label: String) {
        switch event.kind {
        case .received: ("arrow.down", .blue, "Received")
        case .sent: ("paperplane.fill", .green, "Sent")
        case .greeted: ("hand.wave.fill", .pink, "Greeted")
        case .draft: ("doc.text", .orange, "Drafted")
        case .skipped: ("forward.fill", .gray, "Skipped")
        case .error: ("exclamationmark", .red, "Error")
        case .info: ("info", .gray, "Info")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(style.color)
                .frame(width: 26, height: 26)
                .background(style.color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(style.label).font(.caption.weight(.semibold)).foregroundStyle(style.color)
                    if let title = event.title {
                        Text(title).font(.caption.weight(.semibold))
                    }
                    Spacer(minLength: 8)
                    if let ms = event.ms {
                        Text("\(ms) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    Text(event.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(event.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
