import SwiftUI

/// New Message, like Messages: pick someone from Contacts (or type a number or email). If you already have a
/// conversation with them it opens; otherwise you get an empty thread and the first text starts one.
struct NewMessageView: View {
    @Environment(AppState.self) private var state
    /// Open an existing conversation.
    let open: (String) -> Void
    /// A first text went out to this new conversation key; open it once Messages has it.
    let started: (String) -> Void

    @State private var query = ""
    @State private var recipient: ContactsIndex.Entry?
    @State private var draft = ""
    @State private var highlighted = 0
    @FocusState private var focus: Field?

    private enum Field { case to, message }

    var body: some View {
        VStack(spacing: 0) {
            toField
            Divider().opacity(0.6)
            Group {
                if recipient == nil {
                    suggestions
                } else {
                    thread
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // To: sits at the top, right under the toolbar, like Messages.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .floatingBar(.bottom) { if recipient != nil { composer } }
        .onAppear { focus = .to }
    }

    // MARK: To:

    private var toField: some View {
        HStack(spacing: 8) {
            Text("To:").foregroundStyle(.secondary)
            if let recipient {
                HStack(spacing: 6) {
                    Text(recipient.name.isEmpty ? ContactsIndex.pretty(recipient.handle) : recipient.name)
                        .font(.callout.weight(.medium))
                    Button {
                        self.recipient = nil
                        focus = .to
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .liquidGlass(in: Capsule(), tint: Color.accentColor.opacity(0.25))
                Spacer()
            } else {
                TextField("Name, number or email", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .to)
                    .onSubmit { pick(highlighted) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, options.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onChange(of: query) { highlighted = 0 }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 20)
        .frame(height: 48)
    }

    // MARK: Suggestions

    private enum Option: Identifiable {
        case contact(ContactsIndex.Entry)
        case group(ChatSummary)
        case raw(String)

        var id: String {
            switch self {
            case .contact(let e): "c:" + e.handle
            case .group(let c): "g:" + c.id
            case .raw(let h): "r:" + h
            }
        }
    }

    private var options: [Option] {
        let q = query.trimmed
        guard !q.isEmpty else { return [] }
        var out: [Option] = state.contacts.search(q).map { .contact($0) }
        out += state.chats.filter { $0.isGroup && $0.title.localizedCaseInsensitiveContains(q) }.prefix(8).map { .group($0) }
        // A number or email nobody's saved yet.
        let digits = q.filter(\.isNumber)
        let looksLikeEmail = q.contains("@") && q.contains(".") && !q.contains(" ")
        if looksLikeEmail || (digits.count >= 7 && q.allSatisfy { $0.isNumber || " +-().".contains($0) }) {
            out.insert(.raw(q), at: 0)
        }
        return out
    }

    @ViewBuilder private var suggestions: some View {
        let list = options
        if list.isEmpty {
            ContentUnavailableView(query.trimmed.isEmpty ? "New Message" : "No matches",
                                   systemImage: query.trimmed.isEmpty ? "square.and.pencil" : "person.crop.circle.badge.questionmark",
                                   description: Text(query.trimmed.isEmpty
                                                     ? "Type a name from your Contacts, a phone number or an email."
                                                     : "Type a full phone number or email to text someone who isn't in your Contacts."))
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, option in
                        Button { pick(i) } label: { row(option, highlighted: i == highlighted) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
    }

    private func row(_ option: Option, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            switch option {
            case .contact(let entry):
                Avatar(title: entry.name, size: 34, handle: entry.handle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.system(size: 13, weight: .semibold))
                    Text("\(entry.label)  \(entry.handle.contains("@") ? entry.handle : ContactsIndex.pretty(entry.handle))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .group(let chat):
                Avatar(title: chat.title, isGroup: true, size: 34, photoPath: chat.photoPath, members: chat.participants)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Group · \(chat.participants.count + 1) people").font(.caption).foregroundStyle(.secondary)
                }
            case .raw(let handle):
                Image(systemName: handle.contains("@") ? "envelope.fill" : "phone.fill")
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(handle.contains("@") ? handle : ContactsIndex.pretty(handle)).font(.system(size: 13, weight: .semibold))
                    Text("Not in your Contacts").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Picking someone opens your existing conversation with them, if there is one.
    private func pick(_ index: Int) {
        let list = options
        guard list.indices.contains(index) else { return }
        switch list[index] {
        case .group(let chat):
            open(chat.id)
        case .contact(let entry):
            choose(entry)
        case .raw(let handle):
            choose(ContactsIndex.Entry(name: state.contacts.name(for: handle) ?? "", handle: handle, label: ""))
        }
    }

    private func choose(_ entry: ContactsIndex.Entry) {
        Task {
            if let chat = await state.existingChat(with: entry.handle) {
                open(chat.id)
            } else {
                recipient = entry
                focus = .message
            }
        }
    }

    // MARK: Thread

    private var thread: some View {
        let key = recipient.map { ContactsIndex.normalized($0.handle) } ?? ""
        let queue = state.outbox(for: key)
        return ScrollView {
            VStack(spacing: 4) {
                ForEach(queue) { item in
                    Bubble(text: item.text, fromMe: true, faded: item.phase == .queued || item.phase == .sending, failed: item.isFailed) {
                        PendingStatus(item: item) {
                            if let back = state.undoSend(item.id), draft.trimmed.isEmpty { draft = back.text }
                        }
                    } actions: {
                        if item.phase == .queued { Button("Undo Send") { _ = state.undoSend(item.id) } }
                        if item.isFailed { Button("Try Again") { state.retry(item.id, asTextMessage: false) } }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
            if queue.isEmpty, let recipient {
                VStack(spacing: 8) {
                    Avatar(title: recipient.name, size: 56, handle: recipient.handle)
                    Text(recipient.name.isEmpty ? ContactsIndex.pretty(recipient.handle) : recipient.name).font(.headline)
                    Text("No messages yet. Your first text starts the conversation.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var composer: some View {
        GlassGroup(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("iMessage", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focus, equals: .message)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(minHeight: 36)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).frame(width: 20, height: 20)
                }
                .glassCircleButton(prominent: true)
                .disabled(draft.trimmed.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private func send() {
        let text = draft.trimmed
        guard !text.isEmpty, let recipient else { return }
        draft = ""
        started(state.startConversation(with: recipient.handle, text: text))
    }
}
