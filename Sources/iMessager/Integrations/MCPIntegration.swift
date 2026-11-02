import Foundation

/// Minimal Model Context Protocol client over stdio: spawns the server once, keeps it running,
/// lists its tools and forwards calls as JSON-RPC.
actor MCPIntegration: Integration {
    private let config: IntegrationConfig
    private let report: @Sendable (String) -> Void
    private let prefix: String
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var waiters: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var specs: [ToolSpec] = []
    private var originals: [String: String] = [:]
    private var stderrTail = ""
    private var stopping = false

    init(_ config: IntegrationConfig, report: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.report = report
        self.prefix = Slug.make(config.name, max: 24)
    }

    func start() async {
        let command = config.command.trimmed
        guard !command.isEmpty else { report("Add a launch command"); return }
        report("Starting…")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \(command)"]  // login shell so npx/uvx/brew tools resolve
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        for (k, v) in KeyValue.parse(config.env, separator: "=") { env[k] = v }
        p.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        let lines = LineSplitter { [weak self] line in Task { await self?.receive(line) } }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { lines.feed(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.noteStderr(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.exited(status) }
        }

        do { try p.run() } catch {
            report("Couldn't start: \(error.localizedDescription)")
            return
        }
        ChildProcesses.add(p)
        process = p
        input = stdin.fileHandleForWriting

        do {
            _ = try await request("initialize", [
                "protocolVersion": "2025-06-18",
                "capabilities": .object([:]),
                "clientInfo": ["name": "iMessager", "version": "1.0"],
            ], timeout: 90)
            try write(["jsonrpc": "2.0", "method": "notifications/initialized"])

            var collected: [ToolSpec] = []
            var cursor: String?
            repeat {
                let params: JSON = cursor.map { ["cursor": .string($0)] } ?? .object([:])
                let page = try await request("tools/list", params, timeout: 30)
                for tool in page["tools"]?.array ?? [] {
                    guard let name = tool["name"]?.string else { continue }
                    let exposed = String("\(prefix)_\(Slug.make(name, max: 60))".prefix(60))
                    originals[exposed] = name
                    collected.append(ToolSpec(name: exposed, description: tool["description"]?.string ?? name,
                                              parameters: Self.cleanSchema(tool["inputSchema"])))
                }
                cursor = page["nextCursor"]?.string
            } while cursor != nil && collected.count < 200
            specs = collected
            report("Connected · \(collected.count) tool\(collected.count == 1 ? "" : "s")")
        } catch {
            report("Failed: \(error.localizedDescription)\(stderrTail.isEmpty ? "" : " · \(stderrTail)")")
        }
    }

    func tools() async -> [ToolSpec] { specs }

    func call(_ tool: String, _ args: JSON) async throws -> String {
        let arguments: JSON = args.object != nil ? args : .object([:])
        let result = try await request("tools/call", ["name": .string(originals[tool] ?? tool), "arguments": arguments], timeout: 60)
        let parts = (result["content"]?.array ?? []).compactMap { item -> String? in
            switch item["type"]?.string {
            case "text": item["text"]?.string
            case "resource": item["resource"]?["text"]?.string
            case "image": "[image]"
            default: nil
            }
        }
        var text = parts.joined(separator: "\n")
        if text.isEmpty, let structured = result["structuredContent"] { text = structured.compact }
        if result["isError"]?.bool == true { throw AppError(text.isEmpty ? "Tool failed" : text) }
        return text.isEmpty ? "(no output)" : text
    }

    func shutdown() async {
        stopping = true
        failAll(AppError("Server stopped"))
        if let process {
            if process.isRunning { process.terminate() }
            ChildProcesses.remove(process)
        }
        process = nil
        input = nil
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON {
        let id = nextID
        nextID += 1
        let message: JSON = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            do { try write(message) } catch {
                waiters[id] = nil
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id)
            }
        }
    }

    private func write(_ message: JSON) throws {
        guard let input else { throw AppError("Server isn't running") }
        var data = try message.data()
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ line: String) {
        guard let message = try? JSON.parse(Data(line.utf8)) else { return } // ignore non-JSON log noise
        if let method = message["method"]?.string {
            // Server → client request: answer pings, decline anything else.
            guard let id = message["id"] else { return }
            let reply: JSON = method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": .object([:])]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported"]]
            try? write(reply)
            return
        }
        guard let id = message["id"]?.int, let waiter = waiters.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            waiter.resume(throwing: AppError(error["message"]?.string ?? "MCP error"))
        } else {
            waiter.resume(returning: message["result"] ?? .null)
        }
    }

    private func expire(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: AppError("Timed out"))
    }

    private func noteStderr(_ text: String) {
        if let last = text.split(whereSeparator: \.isNewline).last { stderrTail = String(last.prefix(200)) }
    }

    private func exited(_ status: Int32) {
        failAll(AppError("Server exited (\(status))"))
        if let process { ChildProcesses.remove(process) }
        process = nil
        input = nil
        specs = []
        if !stopping { report("Stopped (exit \(status))\(stderrTail.isEmpty ? "" : " · \(stderrTail)")") }
    }

    private func failAll(_ error: Error) {
        let pending = waiters
        waiters = [:]
        pending.values.forEach { $0.resume(throwing: error) }
    }

    private static func cleanSchema(_ schema: JSON?) -> JSON {
        guard var o = schema?.object else { return ["type": "object", "properties": .object([:])] }
        o["$schema"] = nil
        if o["type"] == nil { o["type"] = "object" }
        if o["properties"] == nil { o["properties"] = .object([:]) }
        return .object(o)
    }
}
