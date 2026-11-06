import Foundation

struct ToolSpec: Sendable {
    let name: String
    let description: String
    let parameters: JSON

    var json: JSON {
        ["type": "function",
         "function": ["name": .string(name), "description": .string(description), "parameters": parameters]]
    }

    static func query(_ name: String, _ description: String, hint: String = "What to look up") -> ToolSpec {
        ToolSpec(name: name, description: description, parameters: [
            "type": "object",
            "properties": ["query": ["type": "string", "description": .string(hint)]],
            "required": ["query"],
        ])
    }
}

/// A source of context for the model.
/// `context()` is injected into every prompt (cheap, local, no extra round trip);
/// `tools()` are offered to the model and only run when it asks.
protocol Integration: AnyObject, Sendable {
    func start() async
    func context() async -> String?
    func tools() async -> [ToolSpec]
    func call(_ tool: String, _ args: JSON) async throws -> String
    func shutdown() async
}

extension Integration {
    func start() async {}
    func context() async -> String? { nil }
    func tools() async -> [ToolSpec] { [] }
    func call(_ tool: String, _ args: JSON) async throws -> String { throw AppError("Unknown tool \(tool)") }
    func shutdown() async {}
}

struct HubSnapshot: Sendable {
    var context: [String] = []
    var tools: [ToolSpec] = []
}

actor IntegrationHub {
    typealias Credentials = @Sendable () async -> (key: String, model: String)

    private var live: [UUID: (config: IntegrationConfig, impl: any Integration)] = [:]
    private var order: [UUID] = []
    private var routes: [String: (id: UUID, tool: String)] = [:]
    private var syncChain: Task<Void, Never>?
    private let llm: OpenRouterClient
    private let credentials: Credentials
    private let report: @Sendable (UUID, String?) -> Void

    init(llm: OpenRouterClient, credentials: @escaping Credentials, report: @escaping @Sendable (UUID, String?) -> Void) {
        self.llm = llm
        self.credentials = credentials
        self.report = report
    }

    /// Brings running integrations in line with the config. Unchanged ones keep running (MCP servers stay up).
    func sync(_ configs: [IntegrationConfig]) async {
        let previous = syncChain
        let task = Task { await previous?.value; await self.apply(configs) }
        syncChain = task
        await task.value
    }

    private func apply(_ configs: [IntegrationConfig]) async {
        let wanted = Dictionary(configs.filter(\.enabled).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, entry) in live where wanted[id] != entry.config {
            live[id] = nil
            await entry.impl.shutdown()
            report(id, nil)
        }
        for (id, config) in wanted where live[id] == nil {
            let impl = make(config)
            live[id] = (config, impl)
            Task { await impl.start() }
        }
        order = configs.map(\.id)
    }

    func restart(_ id: UUID) async {
        guard let entry = live[id] else { return }
        await entry.impl.shutdown()
        let impl = make(entry.config)
        live[id] = (entry.config, impl)
        Task { await impl.start() }
    }

    /// Gathers prompt context and tool specs from every live integration in parallel.
    func snapshot() async -> HubSnapshot {
        let entries = order.compactMap { id in live[id].map { (id, $0.impl) } }
        let gathered = await withTaskGroup(of: (Int, String?, [ToolSpec]).self) { group in
            for (i, entry) in entries.enumerated() {
                group.addTask { (i, await entry.1.context(), await entry.1.tools()) }
            }
            var out: [(Int, String?, [ToolSpec])] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }
        }
        var snap = HubSnapshot()
        var newRoutes: [String: (id: UUID, tool: String)] = [:]
        for (i, context, tools) in gathered {
            if let context, !context.trimmed.isEmpty { snap.context.append(context) }
            for tool in tools {
                var name = Slug.make(tool.name, max: 60)
                var n = 2
                while newRoutes[name] != nil || name == Agent.historyTool.name { name = "\(Slug.make(tool.name, max: 57))_\(n)"; n += 1 }
                newRoutes[name] = (entries[i].0, tool.name)
                snap.tools.append(ToolSpec(name: name, description: tool.description, parameters: tool.parameters))
            }
        }
        routes = newRoutes
        return snap
    }

    func call(_ name: String, _ args: JSON) async -> String {
        guard let route = routes[name], let impl = live[route.id]?.impl else { return "Error: unknown tool \(name)" }
        do { return try await impl.call(route.tool, args) } catch { return "Error: \(error.localizedDescription)" }
    }

    /// Only "About Me" context, for the new-contact greeter (which gets no tools: strangers can't trigger them).
    func profileContext() async -> String? {
        let profiles = live.values.filter { $0.config.kind == .profile }.map(\.impl)
        var parts: [String] = []
        for p in profiles { if let c = await p.context() { parts.append(c) } }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    func describe(_ id: UUID) async -> String {
        guard let impl = live[id]?.impl else { return "Turn this integration on first." }
        let context = await impl.context()
        let tools = await impl.tools()
        var out = ""
        if let context, !context.isEmpty {
            out += "Added to every prompt:\n\(context)\n\n"
        } else {
            out += "Nothing added to the prompt.\n\n"
        }
        out += tools.isEmpty ? "No tools." : "Tools the AI can call:\n" + tools.map { "• \($0.name): \($0.description)" }.joined(separator: "\n")
        return out
    }

    private func make(_ config: IntegrationConfig) -> any Integration {
        switch config.kind {
        case .profile: ProfileIntegration(config)
        case .calendar: CalendarIntegration(config)
        case .contacts: ContactsLookupIntegration()
        case .folder: FolderIntegration(config)
        case .webhook: WebhookIntegration(config)
        case .webSearch: WebSearchIntegration(config, llm: llm, credentials: credentials)
        case .mcp:
            MCPIntegration(config) { [report, id = config.id] status in report(id, status) }
        case .remoteMCP:
            RemoteMCPIntegration(config) { [report, id = config.id] status in report(id, status) }
        }
    }
}
