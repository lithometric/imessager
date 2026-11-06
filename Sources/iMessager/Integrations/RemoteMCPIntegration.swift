import Foundation

/// A hosted Model Context Protocol server over Streamable HTTP (JSON-RPC by POST; replies as JSON or an SSE stream),
/// authenticated with headers such as `Authorization: Bearer …`. Works for GitHub's, Guava's and other hosted servers.
actor RemoteMCPIntegration: Integration {
    private let config: IntegrationConfig
    private let report: @Sendable (String) -> Void
    private let prefix: String
    private var sessionID: String?
    private var protocolVersion = "2025-06-18"
    private var nextID = 1
    private var specs: [ToolSpec] = []
    private var originals: [String: String] = [:]

    init(_ config: IntegrationConfig, report: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.report = report
        self.prefix = Slug.make(config.name, max: 24)
    }

    func start() async {
        guard URL(string: config.url.trimmed)?.scheme?.hasPrefix("http") == true else { report("Add the server's URL"); return }
        report("Connecting…")
        do {
            let hello = try await request("initialize", [
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": ["name": "iMessager", "version": "1.0"],
            ])
            if let version = hello["protocolVersion"]?.string { protocolVersion = version }
            try await notify("notifications/initialized")

            var collected: [ToolSpec] = []
            var cursor: String?
            repeat {
                let page = try await request("tools/list", cursor.map { ["cursor": .string($0)] } ?? .object([:]))
                for tool in page["tools"]?.array ?? [] {
                    guard let name = tool["name"]?.string else { continue }
                    let exposed = String("\(prefix)_\(Slug.make(name, max: 60))".prefix(60))
                    originals[exposed] = name
                    collected.append(ToolSpec(name: exposed, description: tool["description"]?.string ?? name,
                                              parameters: MCPIntegration.cleanSchema(tool["inputSchema"])))
                }
                cursor = page["nextCursor"]?.string
            } while cursor != nil && collected.count < 200
            specs = collected
            report("Connected · \(collected.count) tool\(collected.count == 1 ? "" : "s")")
        } catch {
            report("Failed: \(error.localizedDescription)")
        }
    }

    func tools() async -> [ToolSpec] { specs }

    func call(_ tool: String, _ args: JSON) async throws -> String {
        let arguments: JSON = args.object != nil ? args : .object([:])
        return try MCPIntegration.text(from: try await request("tools/call", ["name": .string(originals[tool] ?? tool), "arguments": arguments]))
    }

    func shutdown() async {
        guard let sessionID, let url = URL(string: config.url.trimmed) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        applyHeaders(&req)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Transport

    private func request(_ method: String, _ params: JSON) async throws -> JSON {
        let id = nextID
        nextID += 1
        let (data, response) = try await post(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        let message = try Self.reply(id: id, data: data, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "")
        if let error = message["error"] { throw AppError(error["message"]?.string ?? "MCP error") }
        return message["result"] ?? .null
    }

    private func notify(_ method: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": .string(method)])
    }

    private func post(_ body: JSON, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: config.url.trimmed) else { throw AppError("Bad server URL") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.httpBody = try body.data()
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        applyHeaders(&req)
        // No token in the headers: use the one from browser sign-in, if any.
        if req.value(forHTTPHeaderField: "Authorization") == nil, let token = await MCPAuth.accessToken(for: config.id) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AppError("No response") }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401, 403:
            if retry, MCPAuth.tokens(for: config.id) != nil, await MCPAuth.refreshAfterRejection(config.id) {
                return try await post(body, retry: false)
            }
            let hasToken = req.value(forHTTPHeaderField: "Authorization") != nil
            throw AppError(hasToken ? "The server turned down the token (HTTP \(http.statusCode)). Sign in again or check the token."
                                    : "Needs sign-in: use Sign In with Browser, or paste a token in the headers.")
        case 404 where sessionID != nil:
            sessionID = nil
            throw AppError("The server ended the session; it reconnects on the next restart.")
        default:
            let detail = String(decoding: data.prefix(200), as: UTF8.self).trimmed
            throw AppError("HTTP \(http.statusCode)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    private func applyHeaders(_ req: inout URLRequest) {
        for (key, value) in KeyValue.parse(config.headers, separator: ":") {
            // "Authorization: Bearer" with no token yet means "not signed in", not an empty credential.
            let v = value.trimmed
            if v.isEmpty || v.caseInsensitiveCompare("Bearer") == .orderedSame { continue }
            req.setValue(v, forHTTPHeaderField: key)
        }
    }

    /// The JSON-RPC reply with this id, from a plain JSON body or from the events of an SSE stream.
    private static func reply(id: Int, data: Data, contentType: String) throws -> JSON {
        if !contentType.contains("text/event-stream") {
            return try JSON.parse(data)
        }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for event in text.components(separatedBy: "\n\n") {
            let payload = event.split(separator: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            guard !payload.isEmpty, let message = try? JSON.parse(Data(payload.utf8)), message["id"]?.int == id else { continue }
            return message
        }
        throw AppError("The server's reply had no answer to the request")
    }
}
