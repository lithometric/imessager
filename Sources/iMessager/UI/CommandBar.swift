import SwiftUI

/// Under the search bar: "Ask Claude" when what you typed reads like a question or a request.
struct CommandHint: View {
    @Environment(AppState.self) private var state
    let query: String
    let run: () -> Void

    var body: some View {
        let provider = state.config.provider
        Button(action: run) {
            HStack(spacing: 7) {
                ProviderGlyph(provider: provider, size: 13)
                Text(state.aiReady ? "Ask \(provider == .claudeCode ? "Claude" : "AI")" : "Connect an AI in Settings to ask")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if state.aiReady {
                    Text("⏎").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!state.aiReady)
    }
}

/// One thin line of what the request is doing, right under the search bar.
struct CommandStep: View {
    let step: String

    var body: some View {
        Text(step.hasSuffix("…") ? step : step + "…")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: step)
    }
}

/// The answer, and any texts it drafted for you to look over, edit and send.
struct CommandPanel: View {
    @Environment(AppState.self) private var state
    let run: AppState.CommandRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                ProviderGlyph(provider: state.config.provider, size: 13).padding(.top, 1)
                Text(run.request)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button { state.dismissCommand() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if run.running {
                CommandStep(step: run.step)
            }
            if let error = run.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !run.answer.isEmpty {
                ScrollView {
                    Text(Self.markdown(run.answer))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !run.drafts.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(run.drafts) { DraftRow(draft: $0) }
                    }
                }
                .frame(maxHeight: 250)
                .fixedSize(horizontal: false, vertical: true)
                if !run.running {
                    HStack {
                        Button("Discard") { state.dismissCommand() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await state.sendDrafts() }
                        } label: {
                            Text(run.drafts.count == 1 ? "Send" : "Send All \(run.drafts.count)").font(.caption.weight(.semibold))
                        }
                        .glassButtonStyle(prominent: true)
                        .controlSize(.small)
                    }
                }
            } else if run.sentCount > 0 {
                Label("Sent \(run.sentCount) text\(run.sentCount == 1 ? "" : "s"). Each can be undone from its conversation for a moment.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Bold, italics and links; list dashes become bullets.
    private static func markdown(_ text: String) -> AttributedString {
        let bulleted = text.components(separatedBy: "\n").map { line in
            line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(bulleted)
    }
}

/// A drafted text: who it's to, the words (editable), and a way to drop it.
private struct DraftRow: View {
    @Environment(AppState.self) private var state
    let draft: CommandDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(draft.name).font(.caption.weight(.semibold)).lineLimit(1)
                if draft.chatID == nil {
                    Text("new").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { state.discardDraft(draft.id) } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            TextField("Message", text: Binding(get: { draft.text }, set: { state.editDraft(draft.id, text: $0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...6)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The AI's logo, small, in its color.
struct ProviderGlyph: View {
    let provider: AIProvider
    let size: CGFloat

    var body: some View {
        Group {
            if let logo = Brand.providerLogo(provider) {
                Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: "sparkles").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(provider == .claudeCode ? Brand.providerColor(provider) : Color.accentColor)
    }
}

/// While a request runs, a short bright segment travels around the search bar's edge.
struct WorkingBorder: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            Capsule()
                .strokeBorder(AngularGradient(colors: [.clear, .clear, tint.opacity(0.35), tint, .white.opacity(0.9), .clear],
                                              center: .center, angle: .degrees(turn * 360)),
                              lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}
