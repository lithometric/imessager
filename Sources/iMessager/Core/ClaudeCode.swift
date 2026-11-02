import Foundation

/// Uses your Claude Pro/Max plan the way Anthropic supports it: by running your own Claude Code (`claude -p`).
/// iMessager never reads, copies or stores your Claude login; Claude Code signs in and talks to Anthropic itself.
///
/// Texts come from other people, so every call runs with Claude Code's tools, MCP servers, hooks and settings
/// switched off, in an empty folder, with our own system prompt. A message can't make it read files or run commands.
actor ClaudeCode {
    struct Status: Sendable, Equatable {
        var path: String?
        var version: String?
        var loggedIn = false
        var plan: String?
        var problem: String?

        var ready: Bool { path != nil && loggedIn }
    }

    struct Reply: Sendable {
        let text: String
        let ms: Int
        let inputTokens: Int
        let outputTokens: Int
    }

    static let models: [(id: String, label: String)] = [
        ("haiku", "Haiku · fastest"),
        ("sonnet", "Sonnet"),
        ("opus", "Opus · smartest"),
    ]

    private static let candidates = [
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.local/bin/claude", "~/.claude/local/claude",
        "~/.npm-global/bin/claude", "~/.bun/bin/claude", "~/.volta/bin/claude",
    ].map { ($0 as NSString).expandingTildeInPath }

    /// An empty folder, so Claude Code finds no project files or CLAUDE.md to pull in.
    private static let workDir = ContactsIndex.cacheDirectory.appendingPathComponent("claude-code", isDirectory: true)

    private var resolved: String?

    // MARK: - Status

    func status(customPath: String) async -> Status {
        guard let path = locate(customPath) else {
            return Status(problem: "Claude Code isn't installed. Install it from claude.com/claude-code, then sign in by running claude in Terminal.")
        }
        var status = Status(path: path)
        if let out = try? await run(path, ["--version"], timeout: 15) {
            status.version = String(decoding: out.stdout, as: UTF8.self).trimmed.components(separatedBy: " ").first
        }
        guard let out = try? await run(path, ["auth", "status", "--json"], timeout: 15),
              let json = try? JSON.parse(out.stdout) else {
            status.problem = "Couldn't ask Claude Code whether you're signed in."
            return status
        }
        status.loggedIn = json["loggedIn"]?.bool ?? false
        let method = json["authMethod"]?.string ?? ""
        status.plan = json["subscriptionType"]?.string
        if !status.loggedIn {
            status.problem = "Claude Code isn't signed in. Run claude in Terminal and sign in with your Claude account."
        } else if method != "claude.ai" {
            // Signed in with an API key or a cloud provider: that bills the API, not the Claude plan.
            status.problem = "Claude Code is using \(method.isEmpty ? "an API key" : method), not your Claude plan. Run claude auth login to switch."
        }
        return status
    }

    // MARK: - Completion

    func complete(system: String, prompt: String, model: String, customPath: String) async throws -> Reply {
        guard let path = locate(customPath) else { throw AppError("Claude Code isn't installed.") }
        try FileManager.default.createDirectory(at: Self.workDir, withIntermediateDirectories: true)
        let systemFile = Self.workDir.appendingPathComponent("system-\(UUID().uuidString).txt")
        try Data(system.utf8).write(to: systemFile, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: systemFile.path)
        defer { try? FileManager.default.removeItem(at: systemFile) }

        let args = [
            "-p", "--output-format", "json",
            "--model", model,
            "--system-prompt-file", systemFile.path,
            "--tools", "",                 // no built-in tools (no Bash, Read, Edit, WebFetch…)
            "--strict-mcp-config",         // no MCP servers
            "--setting-sources", "",       // no user/project settings, hooks or CLAUDE.md
            "--no-session-persistence",
        ]
        let clock = ContinuousClock()
        let start = clock.now
        let out = try await run(path, args, stdin: Data(prompt.utf8), timeout: 120)
        guard let json = try? JSON.parse(out.stdout) else {
            let err = String(decoding: out.stderr, as: UTF8.self).trimmed
            throw AppError(err.isEmpty ? "Claude Code didn't return a reply." : "Claude Code: \(err.prefix(300))")
        }
        if json["is_error"]?.bool == true {
            throw AppError("Claude Code: \(json["result"]?.string ?? json["subtype"]?.string ?? "error")")
        }
        return Reply(text: json["result"]?.string ?? "",
                     ms: start.duration(to: clock.now).ms,
                     inputTokens: (json["usage"]?["input_tokens"]?.int ?? 0) + (json["usage"]?["cache_read_input_tokens"]?.int ?? 0),
                     outputTokens: json["usage"]?["output_tokens"]?.int ?? 0)
    }

    // MARK: - Process

    private func locate(_ custom: String) -> String? {
        let fm = FileManager.default
        let custom = (custom.trimmed as NSString).expandingTildeInPath
        if !custom.isEmpty { return fm.isExecutableFile(atPath: custom) ? custom : nil }
        if let resolved, fm.isExecutableFile(atPath: resolved) { return resolved }
        resolved = Self.candidates.first(where: fm.isExecutableFile(atPath:))
        return resolved
    }

    /// Runs Claude Code with a PATH that finds Homebrew/npm installs (apps launched from Finder get a bare PATH),
    /// and without API-key variables, so it uses your Claude login rather than API billing. Cancelling kills it.
    private func run(_ path: String, _ args: [String], stdin: Data? = nil, timeout: Double) async throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = Self.workDir
        var env = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] { env[key] = nil }
        let home = NSHomeDirectory()
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                       "\(home)/.bun/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        try? FileManager.default.createDirectory(at: Self.workDir, withIntermediateDirectories: true)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<(stdout: Data, stderr: Data), Error>) in
                let collected = Collected()
                outPipe.fileHandleForReading.readabilityHandler = { collected.appendOut($0.availableData) }
                errPipe.fileHandleForReading.readabilityHandler = { collected.appendErr($0.availableData) }
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collected.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    collected.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    ChildProcesses.remove(p)
                    if collected.timedOut {
                        done.resume(throwing: AppError("Claude Code took too long to answer."))
                    } else {
                        done.resume(returning: collected.result)
                    }
                }
                do {
                    try process.run()
                    ChildProcesses.add(process)
                    if let stdin { inPipe.fileHandleForWriting.write(stdin) }
                    try? inPipe.fileHandleForWriting.close()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        collected.timedOut = true
                        process.terminate()
                    }
                } catch {
                    done.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Output gathered from a child process's pipes on background queues.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var _timedOut = false

    var timedOut: Bool {
        get { lock.withLock { _timedOut } }
        set { lock.withLock { _timedOut = newValue } }
    }

    var result: (stdout: Data, stderr: Data) { lock.withLock { (out, err) } }

    func appendOut(_ data: Data) { lock.withLock { out.append(data) } }
    func appendErr(_ data: Data) { lock.withLock { err.append(data) } }
}
