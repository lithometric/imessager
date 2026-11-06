import AppKit
import CryptoKit
import Foundation
import Network

/// Browser sign-in for hosted MCP servers that use OAuth (Linear, Notion, Atlassian, Sentry…), per the MCP
/// authorization spec: find the server's authorization server, register iMessager as a client, sign in in your
/// browser (PKCE, answered on a one-off 127.0.0.1 address), and keep the tokens in the Keychain, refreshing them.
enum MCPAuth {
    struct Tokens: Codable, Sendable {
        var access: String
        var refresh: String?
        var expires: Date?
        var clientID: String
        var tokenEndpoint: String
        var resource: String
    }

    /// How the sign-in page is opened. Tests swap this out so nothing opens a browser.
    nonisolated(unsafe) static var openBrowser: @Sendable (URL) -> Void = { url in
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    // MARK: Stored tokens

    private static func account(_ id: UUID) -> String { "mcp-oauth-\(id.uuidString)" }

    static func tokens(for id: UUID) -> Tokens? {
        Keychain.get(account(id)).flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
    }

    static func save(_ tokens: Tokens, for id: UUID) {
        if let data = try? JSONEncoder().encode(tokens) { Keychain.set(String(decoding: data, as: UTF8.self), for: account(id)) }
    }

    static func signOut(_ id: UUID) { Keychain.set("", for: account(id)) }

    /// A usable access token, refreshed first if it's expired or about to be.
    static func accessToken(for id: UUID) async -> String? {
        guard var tokens = tokens(for: id) else { return nil }
        if let expires = tokens.expires, expires < Date().addingTimeInterval(60), let refresh = tokens.refresh {
            guard let fresh = try? await exchange(tokens.tokenEndpoint, [
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": tokens.clientID, "resource": tokens.resource,
            ]) else { return nil }
            tokens.access = fresh.access
            tokens.refresh = fresh.refresh ?? refresh
            tokens.expires = fresh.expires
            save(tokens, for: id)
        }
        return tokens.access
    }

    // MARK: GitHub CLI

    static let githubCLIClient = "github-cli"

    static var githubCLI: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", NSHomeDirectory() + "/.local/bin/gh"].first(where: FileManager.default.isExecutableFile)
    }

    /// GitHub's MCP server doesn't do browser sign-in for other apps, but it accepts the token you're signed in
    /// with in the GitHub CLI (`gh auth token`). It's copied into the Keychain, not the settings file.
    static func useGitHubCLI(id: UUID, resource: String) throws {
        guard let gh = githubCLI else { throw AppError("The GitHub CLI isn't installed (brew install gh).") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "token"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmed
        guard p.terminationStatus == 0, !token.isEmpty else { throw AppError("The GitHub CLI isn't signed in. Run gh auth login in Terminal.") }
        save(Tokens(access: token, refresh: nil, expires: nil, clientID: githubCLIClient, tokenEndpoint: "", resource: resource), for: id)
    }

    /// After a 401: try a refresh. Returns false if there's nothing to refresh with (you need to sign in again).
    static func refreshAfterRejection(_ id: UUID) async -> Bool {
        if let tokens = tokens(for: id), tokens.clientID == githubCLIClient {
            // The CLI may have a newer token than the copy we kept.
            return (try? useGitHubCLI(id: id, resource: tokens.resource)) != nil
        }
        guard var tokens = tokens(for: id), tokens.refresh != nil else { return false }
        tokens.expires = .distantPast
        save(tokens, for: id)
        return await accessToken(for: id) != nil
    }

    // MARK: Sign in

    static func signIn(server: URL, id: UUID) async throws {
        let (resourceMetadata, resource, scopes) = try await protectedResource(server)
        let issuer = resourceMetadata ?? origin(server)
        let meta = try await authorizationServer(issuer)
        guard let authorize = meta["authorization_endpoint"]?.string, let tokenEndpoint = meta["token_endpoint"]?.string else {
            throw AppError("The server didn't say where to sign in.")
        }
        guard let registration = meta["registration_endpoint"]?.string else {
            throw AppError("This server doesn't let apps register for browser sign-in. Paste an access token in the headers instead.")
        }

        let callback = try await Callback.start()
        defer { callback.stop() }
        let redirect = "http://127.0.0.1:\(callback.port)/callback"

        // Dynamic client registration (RFC 7591): iMessager is a public client, so no secret.
        var req = URLRequest(url: URL(string: registration)!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSON.object([
            "client_name": "iMessager",
            "redirect_uris": [.string(redirect)],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]).data()
        let (regData, regResponse) = try await URLSession.shared.data(for: req)
        guard (regResponse as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let clientID = (try? JSON.parse(regData))?["client_id"]?.string else {
            throw AppError("Couldn't register with the server for sign-in.")
        }

        let verifier = randomString(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)
        var components = URLComponents(string: authorize)!
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "resource", value: resource),
        ] + (scopes.isEmpty ? [] : [.init(name: "scope", value: scopes.joined(separator: " "))])
        guard let url = components.url else { throw AppError("Bad sign-in address") }
        openBrowser(url)

        let reply = try await callback.wait(timeout: 300)
        guard reply["state"] == state else { throw AppError("Sign-in came back for a different request; try again.") }
        if let error = reply["error"] { throw AppError("Sign-in was declined (\(error)).") }
        guard let code = reply["code"] else { throw AppError("Sign-in didn't return a code.") }

        let tokens = try await exchange(tokenEndpoint, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": clientID, "code_verifier": verifier, "resource": resource,
        ])
        save(Tokens(access: tokens.access, refresh: tokens.refresh, expires: tokens.expires, clientID: clientID,
                    tokenEndpoint: tokenEndpoint, resource: resource), for: id)
    }

    // MARK: Discovery

    /// Protected-resource metadata (RFC 9728): which authorization server, the resource id and scopes.
    private static func protectedResource(_ server: URL) async throws -> (issuer: String?, resource: String, scopes: [String]) {
        // The 401's WWW-Authenticate header can point straight at the metadata.
        var hint: String?
        var probe = URLRequest(url: server, timeoutInterval: 20)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8)
        if let (_, response) = try? await URLSession.shared.data(for: probe),
           let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate"),
           let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) {
            hint = String(header[range]).replacingOccurrences(of: "resource_metadata=", with: "").replacingOccurrences(of: "\"", with: "")
        }
        let path = server.path == "/" ? "" : server.path
        let candidates = [hint, origin(server) + "/.well-known/oauth-protected-resource" + path,
                          origin(server) + "/.well-known/oauth-protected-resource"].compactMap { $0 }
        for candidate in candidates {
            guard let url = URL(string: candidate), let meta = try? await fetchJSON(url),
                  let issuer = meta["authorization_servers"]?[0]?.string else { continue }
            let scopes = meta["scopes_supported"]?.array?.compactMap(\.string) ?? []
            return (issuer, meta["resource"]?.string ?? server.absoluteString, scopes)
        }
        // Older servers: the MCP server's own origin is the authorization server.
        return (nil, server.absoluteString, [])
    }

    /// Authorization-server metadata (RFC 8414, or OpenID configuration as a fallback).
    private static func authorizationServer(_ issuer: String) async throws -> JSON {
        guard let base = URL(string: issuer) else { throw AppError("Bad authorization server address") }
        let root = origin(base)
        let path = base.path == "/" ? "" : base.path
        let candidates = [root + "/.well-known/oauth-authorization-server" + path, root + "/.well-known/oauth-authorization-server",
                          root + "/.well-known/openid-configuration" + path, issuer.trimmingSuffix("/") + "/.well-known/openid-configuration"]
        for candidate in candidates {
            if let url = URL(string: candidate), let meta = try? await fetchJSON(url), meta["authorization_endpoint"] != nil { return meta }
        }
        throw AppError("This server doesn't offer browser sign-in. Paste an access token in the headers instead.")
    }

    private static func fetchJSON(_ url: URL) async throws -> JSON {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("HTTP error") }
        return try JSON.parse(data)
    }

    private static func exchange(_ endpoint: String, _ form: [String: String]) async throws -> (access: String, refresh: String?, expires: Date?) {
        guard let url = URL(string: endpoint) else { throw AppError("Bad token address") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSON.parse(data)) ?? .null
        guard let access = json["access_token"]?.string else {
            throw AppError(json["error_description"]?.string ?? json["error"]?.string ?? "The server didn't issue a token.")
        }
        let expires = json["expires_in"]?.number.map { Date().addingTimeInterval($0) }
        return (access, json["refresh_token"]?.string, expires)
    }

    private static func origin(_ url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
    }

    private static func randomString(_ bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64URL
    }
}

/// A one-off local web server on 127.0.0.1 that catches the browser's redirect back after sign-in.
private final class Callback: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16
    private let lock = NSLock()
    private var result: [String: String]?
    private var waiter: CheckedContinuation<[String: String], Error>?

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> Callback {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let port: UInt16 = try await withCheckedThrowingContinuation { done in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { done.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { done.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let callback = Callback(listener: listener, port: port)
        listener.newConnectionHandler = { [weak callback] connection in callback?.handle(connection) }
        return callback
    }

    func wait(timeout: Double) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { done in
            lock.lock()
            if let result {
                lock.unlock()
                done.resume(returning: result)
                return
            }
            waiter = done
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(AppError("Sign-in timed out. Try again.")))
            }
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let query = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            let params = Dictionary(query.compactMap { item in item.value.map { (item.name, $0) } }) { a, _ in a }
            let page = """
            <!doctype html><meta charset="utf-8"><title>iMessager</title>
            <body style="font:15px -apple-system;text-align:center;padding:80px;color:#333">
            <h2>\(params["code"] != nil ? "You're signed in" : "Sign-in didn't finish")</h2>
            <p>You can close this tab and go back to iMessager.</p></body>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if params["code"] != nil || params["error"] != nil { self?.finish(.success(params)) }
        }
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        let waiting = waiter
        waiter = nil
        if case .success(let value) = outcome, waiting == nil { result = value }
        lock.unlock()
        waiting?.resume(with: outcome)
    }
}

/// Runs its body the first time only (listener state changes can repeat).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }

    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
