import Foundation

struct Draft: Sendable {
    var text: String?
    var tools: [String] = []
    var ms = 0
}

/// The conversation one reply is for. Previews can't act: their tools would send for real.
private struct Turn: Sendable {
    let key: String
    let guid: String
    let handle: String?
    let canAct: Bool
    let dryRun: Bool
    let maxPerHour: Int
}

/// The harness. Watches chat.db, debounces bursts per conversation, gathers context in parallel,
/// runs a short tool loop against OpenRouter, and hands replies to the outbox.
/// A newer incoming text cancels an in-flight reply; a text you send yourself cancels it too.
actor Agent {
    static let historyTool = ToolSpec.query(
        "search_conversation_history",
        "Search older messages in this conversation (beyond the recent ones shown) for a word or phrase.",
        hint: "Words to look for")

    static let statusTool = ToolSpec(
        name: "message_status",
        description: "Check whether my recent texts in this conversation were sent, delivered, read or not delivered, "
            + "including texts still waiting to go out. Lists an id for each.",
        parameters: ["type": "object", "properties": [
            "limit": ["type": "integer", "description": "How many of my latest texts to check (default 5, max 20)"],
        ]])

    static let sendTool = ToolSpec(
        name: "send_message",
        description: "Send a text in this conversation right away, before your final answer (e.g. to split a long reply or send a link on its own). "
            + "Set as_text_message to send it as SMS instead of iMessage. If this already says everything, finish with NO_REPLY.",
        parameters: ["type": "object", "properties": [
            "text": ["type": "string", "description": "The text to send"],
            "as_text_message": ["type": "boolean", "description": "Send as SMS (green bubble) instead of iMessage"],
        ], "required": ["text"]])

    static let retryTool = ToolSpec(
        name: "retry_failed_message",
        description: "Send one of my texts in this conversation again after it was Not Delivered. "
            + "Set as_text_message to resend it as SMS, which reaches people iMessage can't.",
        parameters: ["type": "object", "properties": [
            "message_id": ["type": "string", "description": "The text's id from message_status or the transcript"],
            "as_text_message": ["type": "boolean", "description": "Resend as SMS instead of iMessage"],
        ], "required": ["message_id"]])

    static let undoTool = ToolSpec(
        name: "undo_send",
        description: "Cancel one of my texts that hasn't gone out yet (still in the undo-send window). Texts that already went out can't be unsent.",
        parameters: ["type": "object", "properties": [
            "message_id": ["type": "string", "description": "The text's id (q-…) from send_message or message_status"],
        ], "required": ["message_id"]])

    static let deleteTool = ToolSpec(
        name: "delete_message",
        description: "Delete one of my texts from this conversation in iMessager. Cancels it if it hasn't gone out; otherwise removes it "
            + "from iMessager and from your context. It stays in Messages on the owner's devices.",
        parameters: ["type": "object", "properties": [
            "message_id": ["type": "string", "description": "The text's id from message_status"],
        ], "required": ["message_id"]])

    static let actionTools = [sendTool, retryTool, undoTool, deleteTool]

    private let state: AppState
    private let db: ChatDB
    private let contacts: ContactsIndex
    private let hub: IntegrationHub
    private let llm: OpenRouterClient
    private let claude: ClaudeCode

    private var cursor: Int64 = 0
    private var watcher: ChatWatcher?
    private var heartbeat: Task<Void, Never>?
    private var polling = false
    private var dirty = false
    private var stalls: [Int64: Int] = [:]
    private var pending: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var echoes: [String: [(text: String, at: Date)]] = [:]
    private var replies: [String: [Date]] = [:]
    private var manualUntil: [String: Date] = [:]
    private var greeted: Set<String> = []

    init(state: AppState, db: ChatDB, contacts: ContactsIndex, hub: IntegrationHub, llm: OpenRouterClient, claude: ClaudeCode) {
        self.state = state
        self.db = db
        self.contacts = contacts
        self.hub = hub
        self.llm = llm
        self.claude = claude
    }

    /// Starts from the newest message, so nothing that arrived while the app was closed gets answered.
    func start() async {
        guard watcher == nil else { return }
        cursor = (try? await db.maxRowID()) ?? 0
        let w = ChatWatcher(directory: (ChatDB.path as NSString).deletingLastPathComponent) { [weak self] in
            Task { await self?.pollAndRefresh() }
        }
        w.start()
        watcher = w
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.poll()
            }
        }
    }

    /// Delivery and read receipts change existing rows, so any write to chat.db refreshes open views.
    private func pollAndRefresh() async {
        await poll()
        await state.chatsDidChange()
    }

    func poll() async {
        guard !polling else { dirty = true; return }
        polling = true
        defer { polling = false }
        repeat {
            dirty = false
            guard let batch = try? await db.messages(after: cursor), !batch.isEmpty else { continue }
            for m in batch {
                // A brand-new row can briefly lack its chat link; give it a few polls to land.
                if m.chatIdentifier == nil, !m.isFromMe, stalls[m.id, default: 0] < 3 {
                    stalls[m.id, default: 0] += 1
                    break
                }
                stalls[m.id] = nil
                cursor = m.id
                await route(m)
            }
            await state.chatsDidChange()
        } while dirty
    }

    // MARK: - Routing

    private func route(_ m: ChatMessage) async {
        // Notify for new texts and tapbacks, like Messages.
        if !m.isFromMe, m.itemType == 0, m.associatedType == 0 || (2000...2007).contains(m.associatedType) {
            await state.notifyIncoming(m)
        }
        guard m.itemType == 0, m.associatedType == 0, let key = m.chatIdentifier, let guid = m.chatGUID else { return }

        if m.isFromMe {
            if takeEcho(key, m.text) { return }
            // You texted yourself (here or from your phone): step back.
            let pause = await state.config.pauseAfterManualMinutes
            if pause > 0 { manualUntil[key] = Date().addingTimeInterval(pause * 60) }
            if let p = pending.removeValue(forKey: key) {
                p.task.cancel()
                await state.log(.info, key, "You replied yourself, so the AI reply was cancelled")
            }
            return
        }

        guard !m.text.isEmpty else { return }
        let config = await state.config

        if config.contacts[key]?.enabled == true {
            await state.log(.received, key, m.text)
            if let until = manualUntil[key], until > Date() {
                await state.log(.skipped, key, "Paused for \(Int(until.timeIntervalSinceNow / 60) + 1) more min because you replied yourself")
                return
            }
            let turn = Turn(key: key, guid: guid, handle: m.isGroup ? nil : m.sender, canAct: true, dryRun: config.dryRun,
                            maxPerHour: config.maxRepliesPerHour)
            schedule(key, delay: config.replyDelay) { await $0.reply(turn) }
        } else if config.greeter.enabled, !m.isGroup, let handle = m.sender, !greeted.contains(key),
                  await isNewContact(handle: handle, key: key) {
            await state.log(.received, key, m.text)
            schedule(key, delay: config.replyDelay) { await $0.greet(key: key, guid: guid, handle: handle) }
        }
    }

    private func schedule(_ key: String, delay: Double, _ work: @escaping @Sendable (Agent) async -> Void) {
        pending[key]?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            await work(self)
            await self.finish(key, id)
        }
        pending[key] = (id, task)
    }

    private func finish(_ key: String, _ id: UUID) {
        if pending[key]?.id == id { pending[key] = nil }
    }

    // MARK: - Replies

    private func reply(_ turn: Turn) async {
        let key = turn.key
        let config = await state.config
        let apiKey = await state.apiKey
        guard await state.aiReady else {
            await state.log(.error, key, config.provider == .claudeCode
                            ? "Claude Code isn't ready. Check Settings › AI." : "Add your OpenRouter API key in Settings")
            return
        }
        guard underRateLimit(key, config.maxRepliesPerHour) else {
            await state.log(.skipped, key, "Hit the limit of \(config.maxRepliesPerHour) replies per hour for this chat")
            return
        }
        // "Claude is replying…" in the text bar until the reply is handed to the outbox (or dropped).
        let token = await state.beginReplying(key)
        defer { Task { [state] in await state.endReplying(key, token) } }
        do {
            let draft = try await compose(turn, config: config, apiKey: apiKey)
            try Task.checkCancellation()
            guard let text = draft.text else {
                await state.log(.skipped, key, draft.tools.isEmpty ? "AI decided no reply was needed" : "AI finished with tools only",
                                ms: draft.ms, detail: Self.toolNote(draft.tools))
                return
            }
            await deliver(text, key: key, guid: turn.guid, handle: turn.handle, dryRun: config.dryRun, tools: draft.tools, ms: draft.ms)
        } catch {
            if !Self.isCancellation(error) { await state.log(.error, key, error.localizedDescription) }
        }
    }

    private func greet(key: String, guid: String, handle: String) async {
        let config = await state.config
        let apiKey = await state.apiKey
        guard await state.aiReady, underRateLimit(key, config.maxRepliesPerHour) else { return }
        let token = await state.beginReplying(key)
        defer { Task { [state] in await state.endReplying(key, token) } }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let theirs = try await db.history(identifier: key, limit: 12).filter { !$0.isFromMe }.map(\.text)
            guard !theirs.isEmpty else { return }
            var system = """
            You screen texts from a number that isn't in the phone owner's contacts. Decide whether the sender is a real person \
            introducing themselves by name (e.g. "hey it's Sarah from the climbing gym"). Spam, marketing, scams, verification codes, \
            wrong numbers and messages without a name don't count.
            Respond with only a JSON object: {"name": "<their name as they gave it, or null>", "reply": "<the owner's short warm text back, or null>"}
            Reply guidance: \(config.greeter.instructions)
            """
            if let profile = await hub.profileContext() { system += "\n\n\(profile)" }
            let texts = "Texts from \(handle):\n" + theirs.joined(separator: "\n")
            let answer: String?
            if config.provider == .claudeCode {
                let reply = try await claude.complete(system: system, prompt: texts, model: config.claudeCodeModel,
                                                      customPath: config.claudeCodePath)
                await state.recordClaudeUsage(reply)
                answer = reply.text
            } else {
            var body: [String: JSON] = [
                "model": .string(config.model),
                "messages": [
                    ["role": "system", "content": .string(system)],
                    ["role": "user", "content": .string(texts)],
                ],
                "max_tokens": 300,
                "temperature": 0.4,
                "usage": ["include": true],
            ]
            if config.fastRouting { body["provider"] = ["sort": "latency"] }
            let response = try await llm.chat(.object(body), key: apiKey)
            await state.recordUsage(response["usage"])
            answer = response["choices"]?[0]?["message"]?["content"]?.string
            }
            let ms = start.duration(to: clock.now).ms
            guard let verdict = Self.jsonObject(in: answer),
                  let name = verdict["name"]?.string?.trimmed, !name.isEmpty, name.lowercased() != "null",
                  let text = verdict["reply"]?.string?.trimmed, !text.isEmpty else {
                await state.log(.skipped, key, "New number didn't introduce themselves, so it was left alone", ms: ms)
                return
            }
            try Task.checkCancellation()
            greeted.insert(key)
            await deliver(text, key: key, guid: guid, handle: handle, dryRun: config.dryRun, tools: [], ms: ms, origin: .greeter)
            guard !config.dryRun else { return }

            var notes: [String] = []
            if config.greeter.saveToContacts {
                do {
                    try contacts.save(name: name, handle: handle)
                    notes.append("Saved \(name) to Contacts")
                } catch {
                    notes.append("Couldn't save contact: \(error.localizedDescription)")
                }
            }
            if config.greeter.enableAutoReply {
                await state.setEnabled(key, true)
                notes.append("auto-reply turned on")
            }
            if !notes.isEmpty { await state.log(.info, key, notes.joined(separator: " · ")) }
            await state.chatsDidChange()
        } catch {
            if !Self.isCancellation(error) { await state.log(.error, key, error.localizedDescription) }
        }
    }

    // MARK: - Manual actions from the UI

    func preview(key: String) async throws -> Draft {
        let apiKey = await state.apiKey
        let config = await state.config
        guard await state.aiReady else {
            throw AppError(config.provider == .claudeCode ? "Claude Code isn't ready. Check Settings › AI." : "Add your OpenRouter API key in Settings first.")
        }
        let turn = Turn(key: key, guid: "", handle: nil, canAct: false, dryRun: true, maxPerHour: config.maxRepliesPerHour)
        return try await compose(turn, config: config, apiKey: apiKey)
    }

    /// One-line summary of unread texts for the conversation list, like Apple's notification summaries.
    func summarize(title: String, texts: [String]) async throws -> String? {
        let config = await state.config
        guard await state.aiReady, !texts.isEmpty else { return nil }
        let system = """
        Summarize these unread text messages from \(title) in one line of at most 90 characters, the way a phone \
        summarizes notifications: the gist, in plain words, no quotes, no name prefix, no emoji. Output only the summary.
        """
        let prompt = texts.joined(separator: "\n")
        let raw: String?
        if config.provider == .claudeCode {
            let reply = try await claude.complete(system: system, prompt: prompt, model: "haiku", customPath: config.claudeCodePath)
            await state.recordClaudeUsage(reply)
            raw = reply.text
        } else {
            let apiKey = await state.apiKey
            var body: [String: JSON] = [
                "model": .string(config.model),
                "messages": [["role": "system", "content": .string(system)], ["role": "user", "content": .string(prompt)]],
                "max_tokens": 80,
                "usage": ["include": true],
            ]
            if config.fastRouting { body["provider"] = ["sort": "latency"] }
            let response = try await llm.chat(.object(body), key: apiKey)
            await state.recordUsage(response["usage"])
            raw = response["choices"]?[0]?["message"]?["content"]?.string
        }
        guard let line = raw?.trimmed.split(separator: "\n").first.map(String.init)?.trimmed, !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(117)) + "…" : line
    }

    /// You're sending from iMessager: same as replying from your phone, so any pending AI reply is dropped.
    func userIsReplying(_ key: String) async {
        let pause = await state.config.pauseAfterManualMinutes
        if pause > 0 { manualUntil[key] = Date().addingTimeInterval(pause * 60) }
        if let p = pending.removeValue(forKey: key) {
            p.task.cancel()
            await state.log(.info, key, "You replied yourself, so the AI reply was cancelled")
        }
    }

    /// The outbox calls this right before handing an AI text to Messages, so its chat.db row isn't mistaken for you.
    func expectEcho(_ key: String, _ text: String) {
        echoes[key, default: []].append((Self.normalize(text), Date()))
    }

    // MARK: - Composition

    private func compose(_ turn: Turn, config: AppConfig, apiKey: String) async throws -> Draft {
        let key = turn.key
        let clock = ContinuousClock()
        let start = clock.now
        async let historyRequest = db.history(identifier: key, limit: config.historyLimit)
        async let snapshotRequest = hub.snapshot()
        // Deleted and unsent texts are out of the model's view too.
        let history = try await historyRequest.filter { !$0.isRetracted && !config.hiddenMessages.contains($0.guid) }
        let snapshot = await snapshotRequest
        guard !history.isEmpty else { return Draft(text: nil) }

        let isGroup = history.contains(where: \.isGroup)
        let title = await state.title(for: key)
        var system = systemPrompt(config: config, key: key, title: title, isGroup: isGroup, snapshot: snapshot)
        // Claude Code runs with its tools off, so the reply comes from the transcript and injected context alone.
        if config.provider == .claudeCode {
            let reply = try await claude.complete(system: system, prompt: transcript(history, title: title, isGroup: isGroup),
                                                  model: config.claudeCodeModel, customPath: config.claudeCodePath)
            await state.recordClaudeUsage(reply)
            return Draft(text: Self.clean(reply.text), tools: [], ms: start.duration(to: clock.now).ms)
        }
        if turn.canAct, history.contains(where: { $0.status == .failed }) {
            system += "\nSome of my recent texts were not delivered (marked in the transcript). retry_failed_message can resend them, as SMS if iMessage isn't reaching them."
        }
        var messages: [JSON] = [
            ["role": "system", "content": .string(system)],
            ["role": "user", "content": .string(transcript(history, title: title, isGroup: isGroup))],
        ]
        var tools = [Self.historyTool, Self.statusTool] + (turn.canAct ? Self.actionTools : []) + snapshot.tools
        var used: [String] = []
        let maxSteps = 4

        for step in 0...maxSteps {
            var body: [String: JSON] = [
                "model": .string(config.model),
                "messages": .array(messages),
                "max_tokens": 600,
                "temperature": 0.7,
                "usage": ["include": true],
            ]
            if !tools.isEmpty {
                body["tools"] = .array(tools.map(\.json))
                if step == maxSteps { body["tool_choice"] = "none" }
            }
            if config.fastRouting { body["provider"] = ["sort": "latency"] }

            let response: JSON
            do {
                response = try await llm.chat(.object(body), key: apiKey)
            } catch where step == 0 && !tools.isEmpty && error.localizedDescription.lowercased().contains("tool") {
                tools = [] // model can't do tool calls: answer from the injected context alone
                response = try await llm.chat(.object(body.filter { $0.key != "tools" && $0.key != "tool_choice" }), key: apiKey)
            }

            await state.recordUsage(response["usage"])
            let message = response["choices"]?[0]?["message"] ?? .null
            let calls = message["tool_calls"]?.array ?? []
            if calls.isEmpty || step == maxSteps {
                return Draft(text: Self.clean(message["content"]?.string), tools: used, ms: start.duration(to: clock.now).ms)
            }

            var assistant: [String: JSON] = ["role": "assistant", "content": message["content"] ?? "", "tool_calls": .array(calls)]
            if let details = message["reasoning_details"] { assistant["reasoning_details"] = details }
            messages.append(.object(assistant))

            // Run every requested tool at once.
            let results = await withTaskGroup(of: (Int, String).self) { group in
                for (i, call) in calls.enumerated() {
                    group.addTask { (i, await self.runTool(call, turn)) }
                }
                var out = [String](repeating: "", count: calls.count)
                for await (i, result) in group { out[i] = result }
                return out
            }
            for (call, result) in zip(calls, results) {
                messages.append(["role": "tool", "tool_call_id": call["id"] ?? "", "content": .string(result)])
                if let name = call["function"]?["name"]?.string { used.append(name) }
            }
        }
        return Draft(text: nil, tools: used, ms: start.duration(to: clock.now).ms)
    }

    private func runTool(_ call: JSON, _ turn: Turn) async -> String {
        let name = call["function"]?["name"]?.string ?? ""
        let rawArgs = call["function"]?["arguments"]
        let args = rawArgs?.object != nil ? rawArgs! : ((try? JSON.parse(Data((rawArgs?.string ?? "{}").utf8))) ?? .object([:]))
        let result: String
        switch name {
        case Self.historyTool.name:
            let hits = (try? await db.search(identifier: turn.key, query: args["query"]?.string ?? "", scan: 5000, limit: 12)) ?? []
            result = hits.isEmpty ? "No matches." : hits.map { "[\(Self.stamp($0.date))] \($0.isFromMe ? "Me" : "Them"): \($0.text)" }.joined(separator: "\n")
        case Self.statusTool.name:
            result = await messageStatus(turn, limit: args["limit"]?.int ?? 5)
        case _ where Self.actionTools.contains(where: { $0.name == name }):
            result = turn.canAct ? await act(name, args, turn) : "Not available while drafting."
        default:
            result = await hub.call(name, args)
        }
        return String(result.prefix(8000))
    }

    // MARK: - Messaging tools (scoped to the current conversation)

    private func messageStatus(_ turn: Turn, limit: Int) async -> String {
        let hidden = await state.config.hiddenMessages
        let mine = ((try? await db.history(identifier: turn.key, limit: 80)) ?? [])
            .filter { $0.isFromMe && !$0.isRetracted && !hidden.contains($0.guid) }
            .suffix(min(max(limit, 1), 20))
        var lines = mine.map { m in
            "id \(m.id) · \(Self.stamp(m.date)) · \(m.isTextMessage ? "SMS" : "iMessage") · \(m.status?.label ?? "Sent") · \"\(Self.snippet(m.text))\""
        }
        let queued = await state.outbox(for: turn.key).filter { $0.phase != .sent }
        lines += queued.map { "id \($0.ref) · \($0.phaseLabel) · \"\(Self.snippet($0.text))\"" }
        return lines.isEmpty ? "I haven't sent anything in this conversation yet." : lines.joined(separator: "\n")
    }

    private func act(_ name: String, _ args: JSON, _ turn: Turn) async -> String {
        let key = turn.key
        let ref = (args["message_id"]?.string ?? args["message_id"]?.int.map(String.init) ?? "").trimmed
        let asText = args["as_text_message"]?.bool ?? false
        let queued = ref.hasPrefix("q-") ? await state.outgoing(ref: ref, chat: key) : nil
        let sent: ChatMessage? = if let id = Int64(ref.replacingOccurrences(of: "id ", with: "")),
            let m = try? await db.message(id: id), m.chatIdentifier == key, m.isFromMe { m } else { nil }

        switch name {
        case Self.sendTool.name:
            let text = Self.clean(args["text"]?.string) ?? ""
            guard !text.isEmpty else { return "Nothing to send." }
            if turn.dryRun {
                await state.log(.draft, key, text, detail: "Dry run, not sent · send_message")
                return "Dry run is on, so it wasn't sent."
            }
            guard underRateLimit(key, turn.maxPerHour) else { return "Hit the hourly limit for this chat, so it wasn't sent." }
            replies[key, default: []].append(Date())
            let item = await state.enqueue(text, chat: key, guid: turn.guid, handle: turn.handle, origin: .ai, asTextMessage: asText,
                                           detail: "send_message")
            let wait = Int(item.sendAt.timeIntervalSinceNow.rounded(.up))
            return wait > 0 ? "Queued as \(item.ref); it goes out in \(wait)s unless you undo_send it." : "Sending now as \(item.ref)."

        case Self.retryTool.name:
            if let queued {
                guard queued.isFailed else { return "\(ref) didn't fail (\(queued.phaseLabel))." }
                guard !turn.dryRun else { return "Dry run is on, so it wasn't resent." }
                await state.retry(queued.id, asTextMessage: asText)
                return "Trying \(ref) again\(asText ? " as a text message" : "")."
            }
            guard let sent else { return "Couldn't find a text of mine with id \(ref) in this conversation." }
            guard sent.status == .failed else { return "Text \(ref) wasn't a failed one (\(sent.status?.label ?? "Sent")), so there's nothing to retry." }
            guard !turn.dryRun else { return "Dry run is on, so it wasn't resent." }
            guard underRateLimit(key, turn.maxPerHour) else { return "Hit the hourly limit for this chat, so it wasn't resent." }
            replies[key, default: []].append(Date())
            let item = await state.resend(sent, guid: turn.guid, handle: turn.handle, asTextMessage: asText, origin: .ai)
            return "Resending as \(item.ref)\(asText ? " (text message)" : ""). The failed copy is hidden."

        case Self.undoTool.name:
            guard let queued else {
                return sent == nil && !ref.hasPrefix("q-") ? "Couldn't find a text of mine with id \(ref) in this conversation."
                    : "That text already went out, and Messages doesn't let other apps unsend. Send a quick correction if it matters."
            }
            switch queued.phase {
            case .queued:
                await state.undoSend(queued.id)
                return "Cancelled \(ref). It never went out."
            case .failed:
                await state.discard(queued.id)
                return "\(ref) had failed, so it's removed."
            default:
                return "\(ref) already went out, and Messages doesn't let other apps unsend. Send a quick correction if it matters."
            }

        case Self.deleteTool.name:
            if let queued {
                guard queued.phase == .queued || queued.isFailed else { return "\(ref) already went out. Check message_status for its id, then delete that." }
                await state.discard(queued.id)
                await state.log(.info, key, "AI deleted a text before it went out: \(queued.text)")
                return "Deleted \(ref) before it went out."
            }
            guard let sent else { return "Couldn't find a text of mine with id \(ref) in this conversation." }
            await state.hide(sent)
            await state.log(.info, key, "AI deleted a text from iMessager: \(sent.text)")
            return "Deleted text \(ref) from iMessager. It's still in Messages on the owner's devices."

        default:
            return "Unknown tool \(name)"
        }
    }

    private func systemPrompt(config: AppConfig, key: String, title: String, isGroup: Bool, snapshot: HubSnapshot) -> String {
        var s = config.persona.trimmed
        s += "\n\nIt is now \(Date().formatted(date: .complete, time: .shortened)) (\(TimeZone.current.identifier))."
        s += isGroup
            ? "\nThis is the group chat \"\(title)\". Only reply when someone addresses me or a reply is clearly natural."
            : "\nI'm texting with \(title) (\(key))."
        if let notes = config.contacts[key]?.instructions.trimmed, !notes.isEmpty {
            s += "\n\nInstructions for this conversation:\n\(notes)"
        }
        for context in snapshot.context { s += "\n\n\(context)" }
        s += """


        Output only the text message to send: no quotes, labels or explanations. \
        If no reply is needed (the conversation wrapped up, or it was just a reaction), output exactly NO_REPLY.
        """
        return s
    }

    private func transcript(_ history: [ChatMessage], title: String, isGroup: Bool) -> String {
        let lines = history.map { m -> String in
            let me = m.status == .failed ? "Me (not delivered, id \(m.id))" : "Me"
            let who = m.isFromMe ? me : (isGroup ? (m.sender.map { contacts.name(for: $0) ?? ContactsIndex.pretty($0) } ?? "Someone") : title)
            var body = m.attachments.isEmpty ? m.text : (m.attachments.map(\.label) + [m.caption]).filter { !$0.isEmpty }.joined(separator: " ")
            if !m.reactions.isEmpty {
                let notes = m.reactions.map { r in "\(r.fromMe ? "I" : (r.sender.map { contacts.name(for: $0) ?? ContactsIndex.pretty($0) } ?? "they")) \(r.verb) this" }
                body += " (\(notes.joined(separator: "; ")))"
            }
            return "[\(Self.stamp(m.date))] \(who): \(body)"
        }
        return "Recent messages, oldest first:\n" + lines.joined(separator: "\n") + "\n\nWrite my next text."
    }

    // MARK: - Delivery & bookkeeping

    /// Hands a reply to the outbox, which holds it for the undo window if you've asked for that.
    private func deliver(_ text: String, key: String, guid: String, handle: String?, dryRun: Bool, tools: [String], ms: Int?,
                         origin: SendOrigin = .ai) async {
        let detail = Self.toolNote(tools)
        if dryRun {
            await state.log(.draft, key, text, ms: ms, detail: ["Dry run, not sent", detail].compactMap { $0 }.joined(separator: " · "))
            return
        }
        replies[key, default: []].append(Date())
        await state.enqueue(text, chat: key, guid: guid, handle: handle, origin: origin, ms: ms, detail: detail)
    }

    /// True if this outgoing row is a message the agent itself just sent.
    private func takeEcho(_ key: String, _ text: String) -> Bool {
        let cutoff = Date().addingTimeInterval(-180)
        var list = (echoes[key] ?? []).filter { $0.at > cutoff }
        defer { echoes[key] = list.isEmpty ? nil : list }
        guard let i = list.firstIndex(where: { $0.text == Self.normalize(text) }) else { return false }
        list.remove(at: i)
        return true
    }

    private func underRateLimit(_ key: String, _ limit: Int) -> Bool {
        let cutoff = Date().addingTimeInterval(-3600)
        let recent = (replies[key] ?? []).filter { $0 > cutoff }
        replies[key] = recent
        return recent.count < limit
    }

    private func isNewContact(handle: String, key: String) async -> Bool {
        guard contacts.authorized, contacts.name(for: handle) == nil else { return false }
        guard handle.contains("@") || handle.filter(\.isNumber).count >= 10 else { return false } // skip short codes
        return ((try? await db.sentCount(identifier: key)) ?? 1) == 0
    }

    // MARK: - Helpers

    private static func clean(_ raw: String?) -> String? {
        guard var t = raw?.trimmed, !t.isEmpty, !t.contains("NO_REPLY") else { return nil }
        if let r = t.range(of: #"^\[[^\]]{3,40}\]\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        if t.hasPrefix("Me:") { t = String(t.dropFirst(3)).trimmed }
        if t.count > 1, t.first == "\"", t.last == "\"" { t = String(t.dropFirst().dropLast()) }
        t = t.trimmed
        return t.isEmpty ? nil : t
    }

    private static func toolNote(_ tools: [String]) -> String? {
        tools.isEmpty ? nil : "Used " + Array(Set(tools)).sorted().joined(separator: ", ")
    }

    private static func snippet(_ s: String) -> String {
        let flat = normalize(s)
        return flat.count > 90 ? flat.prefix(90) + "…" : flat
    }

    private static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func jsonObject(in text: String?) -> JSON? {
        guard let text, let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        return try? JSON.parse(Data(text[open...close].utf8))
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
