import Foundation

struct ORModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let context: Int
    let promptPerM: Double
    let completionPerM: Double
    let tools: Bool

    var priceLabel: String {
        if promptPerM == 0 && completionPerM == 0 { return "free" }
        return String(format: "$%.2f / $%.2f per M", promptPerM, completionPerM)
    }
}

/// Thin OpenRouter client. One shared HTTP/2 session, kept warm so replies skip the TLS handshake.
final class OpenRouterClient: Sendable {
    private static let base = URL(string: "https://openrouter.ai/api/v1/")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 6
        config.httpAdditionalHeaders = [
            "HTTP-Referer": "https://github.com/lithometric/imessager",
            "X-Title": "iMessager",
        ]
        session = URLSession(configuration: config)
    }

    func chat(_ body: JSON, key: String) async throws -> JSON {
        var request = URLRequest(url: Self.base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.data()
        let (data, response) = try await session.data(for: request)
        let json = (try? JSON.parse(data)) ?? .null
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let message = json["error"]?["message"]?.string { throw AppError("OpenRouter: \(message)") }
        guard (200..<300).contains(status) else { throw AppError("OpenRouter returned HTTP \(status)") }
        return json
    }

    func keyInfo(key: String) async throws -> JSON {
        var request = URLRequest(url: Self.base.appendingPathComponent("key"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let json = (try? JSON.parse(data)) ?? .null
        if let message = json["error"]?["message"]?.string { throw AppError(message) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("Key check failed") }
        return json["data"] ?? .null
    }

    /// Opens the connection ahead of the first reply.
    func warm(key: String) async {
        _ = try? await keyInfo(key: key)
    }

    func models() async throws -> [ORModel] {
        let (data, _) = try await session.data(from: Self.base.appendingPathComponent("models"))
        let json = try JSON.parse(data)
        return (json["data"]?.array ?? []).compactMap { m -> ORModel? in
            guard let id = m["id"]?.string else { return nil }
            let prompt = Double(m["pricing"]?["prompt"]?.string ?? "") ?? 0
            let completion = Double(m["pricing"]?["completion"]?.string ?? "") ?? 0
            return ORModel(id: id, name: m["name"]?.string ?? id, context: m["context_length"]?.int ?? 0,
                           promptPerM: prompt * 1_000_000, completionPerM: completion * 1_000_000,
                           tools: (m["supported_parameters"]?.array ?? []).contains("tools"))
        }
        .sorted { $0.id < $1.id }
    }
}
