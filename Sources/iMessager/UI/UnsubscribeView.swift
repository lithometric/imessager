import SwiftUI

/// Promotional senders to unsubscribe from (by texting STOP), checked by default, and the ones you already have.
struct UnsubscribeView: View {
    @Environment(AppState.self) private var state
    @State private var selected: Set<String> = []
    @State private var started = false
    @State private var confirming = false

    var body: some View {
        let all = state.unsubscribeCandidates
        let waiting = all.filter { state.config.unsubscribed[$0.id] == nil }
        let done = all.filter { state.config.unsubscribed[$0.id] != nil }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Texts from businesses sorted into Promotions. Unsubscribing replies STOP, the opt-out carriers require businesses to honor. Codes, banks and deliveries (Transactions), your contacts, groups and anyone you've texted yourself are never listed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: Binding(get: { state.config.autoUnsubscribe }, set: { on in
                    state.config.autoUnsubscribe = on
                    if on { state.config.autoUnsubscribeSince = .now }
                })) {
                    Text("Unsubscribe automatically")
                    Text("New promotional texts get STOP as they arrive, up to 10 a day. What's already here stays below for you to choose.")
                }
                .toggleStyle(.switch)
            }
            .padding(20)
            Divider()
            if all.isEmpty {
                ContentUnavailableView("No promotional texts", systemImage: "bell.slash",
                                       description: Text("Nothing in Promotions to unsubscribe from."))
            } else {
                List {
                    if !waiting.isEmpty {
                        Section("To unsubscribe · \(waiting.count)") {
                            ForEach(waiting) { row($0, done: false) }
                        }
                    }
                    if !done.isEmpty {
                        Section("Unsubscribed · \(done.count)") {
                            ForEach(done) { row($0, done: true) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                Divider()
                HStack {
                    Button(selected.count == waiting.count ? "Select None" : "Select All") {
                        selected = selected.count == waiting.count ? [] : Set(waiting.map(\.id))
                    }
                    .disabled(waiting.isEmpty)
                    Spacer()
                    Button("Unsubscribe from \(selected.count)") { confirming = true }
                        .glassButtonStyle(prominent: true)
                        .disabled(selected.isEmpty)
                }
                .padding(16)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            selected = Set(waiting.map(\.id))
        }
        .confirmationDialog("Text STOP to \(selected.count) sender\(selected.count == 1 ? "" : "s")?", isPresented: $confirming) {
            Button("Send STOP") {
                let ids = Array(selected)
                selected = []
                Task { await state.unsubscribe(ids) }
            }
        } message: {
            Text("Each gets one text saying STOP from your number. You can undo each for a few seconds from its conversation.")
        }
    }

    private func row(_ chat: ChatSummary, done: Bool) -> some View {
        HStack(spacing: 10) {
            if !done {
                Toggle("", isOn: Binding(get: { selected.contains(chat.id) }, set: { on in
                    if on { selected.insert(chat.id) } else { selected.remove(chat.id) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            Avatar(title: chat.title, size: 30, handle: chat.id, glass: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(chat.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if done, state.stillTexting(chat) {
                Text("Still texting").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else if done, let sent = state.config.unsubscribed[chat.id] {
                Text("STOP sent \(sent.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(Fmt.short(chat.lastDate)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !done else { return }
            if selected.contains(chat.id) { selected.remove(chat.id) } else { selected.insert(chat.id) }
        }
        .contextMenu {
            Button("Open Conversation") {
                state.modal = nil
                state.openRequest = chat.id
            }
        }
    }
}
