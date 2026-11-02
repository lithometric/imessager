import Contacts
import EventKit
import Foundation

final class ProfileIntegration: Integration {
    private let notes: String

    init(_ config: IntegrationConfig) { notes = config.notes.trimmed }

    func context() async -> String? {
        notes.isEmpty ? nil : "About me (the phone's owner):\n\(notes)"
    }
}

final class CalendarIntegration: Integration, @unchecked Sendable {
    private let store = EKEventStore()
    private let days: Int

    init(_ config: IntegrationConfig) { days = max(0, config.days) }

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func start() async { _ = await access() }

    func context() async -> String? {
        guard days > 0, await access() else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let list = events(from: start, to: end, limit: 30)
        return "My calendar, next \(days) day\(days == 1 ? "" : "s"):\n" + (list.isEmpty ? "Nothing scheduled." : list)
    }

    func tools() async -> [ToolSpec] {
        [ToolSpec(name: "calendar_events",
                  description: "Look up my calendar for a date range, to check availability or plans beyond what's already shown.",
                  parameters: [
                      "type": "object",
                      "properties": [
                          "start_date": ["type": "string", "description": "YYYY-MM-DD; defaults to today"],
                          "days": ["type": "integer", "description": "How many days to include (1-31)"],
                      ],
                  ])]
    }

    func call(_ tool: String, _ args: JSON) async throws -> String {
        guard await access() else { throw AppError("Calendar access isn't granted") }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        let start = args["start_date"]?.string.flatMap(parser.date(from:)) ?? Calendar.current.startOfDay(for: Date())
        let span = min(max(args["days"]?.int ?? 7, 1), 31)
        let end = Calendar.current.date(byAdding: .day, value: span, to: start)!
        let list = events(from: start, to: end, limit: 80)
        return list.isEmpty ? "No events." : list
    }

    private func access() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    private func events(from start: Date, to end: Date, limit: Int) -> String {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let day = DateFormatter()
        day.dateFormat = "EEE MMM d"
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { e in
                let when = e.isAllDay
                    ? "\(day.string(from: e.startDate)) (all day)"
                    : "\(day.string(from: e.startDate)) \(time.string(from: e.startDate))–\(time.string(from: e.endDate))"
                var line = "- \(when): \(e.title ?? "Busy")"
                if let location = e.location, !location.isEmpty { line += " @ \(location)" }
                return line
            }
            .joined(separator: "\n")
    }
}

final class ContactsLookupIntegration: Integration, @unchecked Sendable {
    private let store = CNContactStore()

    func tools() async -> [ToolSpec] {
        [.query("lookup_contact", "Find people in my Contacts by name: phone, email, birthday, company, city.", hint: "A person's name")]
    }

    func call(_ tool: String, _ args: JSON) async throws -> String {
        let query = args["query"]?.string?.trimmed ?? ""
        guard !query.isEmpty else { return "Give a name to look up." }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                    CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey,
                    CNContactPostalAddressesKey] as [CNKeyDescriptor]
        let matches = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
        guard !matches.isEmpty else { return "No contacts match \"\(query)\"." }
        return matches.prefix(5).map { c in
            var lines = ["\(ContactsIndex.displayName(c))"]
            if !c.organizationName.isEmpty { lines.append("  works at: \([c.jobTitle, c.organizationName].filter { !$0.isEmpty }.joined(separator: ", "))") }
            if let b = c.birthday, let month = b.month, let day = b.day { lines.append("  birthday: \(month)/\(day)\(b.year.map { "/\($0)" } ?? "")") }
            if !c.phoneNumbers.isEmpty { lines.append("  phone: " + c.phoneNumbers.map(\.value.stringValue).joined(separator: ", ")) }
            if !c.emailAddresses.isEmpty { lines.append("  email: " + c.emailAddresses.map { $0.value as String }.joined(separator: ", ")) }
            if let city = c.postalAddresses.first?.value.city, !city.isEmpty { lines.append("  city: \(city)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// A folder of .md/.txt notes. Tiny folders are injected whole; larger ones become a search tool.
actor FolderIntegration: Integration {
    private static let extensions: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml"]
    private static let injectLimit = 4000

    private let name: String
    private let root: URL
    private var cache: [String: (modified: Date, text: String)] = [:]

    init(_ config: IntegrationConfig) {
        name = config.name
        root = URL(fileURLWithPath: (config.path as NSString).expandingTildeInPath, isDirectory: true)
    }

    func context() async -> String? {
        let docs = load()
        let total = docs.reduce(0) { $0 + $1.text.count }
        guard total > 0, total <= Self.injectLimit else { return nil }
        return "My notes (\(name)):\n" + docs.map { "## \($0.name)\n\($0.text)" }.joined(separator: "\n\n")
    }

    func tools() async -> [ToolSpec] {
        let total = load().reduce(0) { $0 + $1.text.count }
        guard total > Self.injectLimit else { return [] }
        return [.query("search_\(Slug.make(name, max: 40))", "Search my \(name) notes for facts, plans, preferences or details.")]
    }

    func call(_ tool: String, _ args: JSON) async throws -> String {
        let terms = (args["query"]?.string ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard !terms.isEmpty else { return "Give some words to search for." }
        var hits: [(score: Int, text: String)] = []
        for doc in load() {
            let fileBonus = terms.filter { doc.name.lowercased().contains($0) }.count * 2
            for chunk in Self.chunks(doc.text) {
                let lower = chunk.lowercased()
                // Rank by how many different query words appear, then by raw frequency.
                let counts = terms.map { lower.components(separatedBy: $0).count - 1 }
                let distinct = counts.filter { $0 > 0 }.count
                if distinct > 0 { hits.append((distinct * 1000 + counts.reduce(0, +) + fileBonus, "From \(doc.name):\n\(chunk)")) }
            }
        }
        let top = hits.sorted { $0.score > $1.score }.prefix(4).map(\.text)
        return top.isEmpty ? "No matches." : top.joined(separator: "\n\n")
    }

    private static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n\n") {
            if current.count + para.count > 700, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + para
        }
        if !current.trimmed.isEmpty { out.append(current) }
        return out.map { String($0.prefix(900)) }
    }

    private func load() -> [(name: String, text: String)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [(String, String)] = []
        var seen = Set<String>()
        for case let url as URL in walker {
            guard out.count < 800 else { break }
            guard Self.extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 512_000 else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            seen.insert(url.path)
            if let hit = cache[url.path], hit.modified == modified {
                out.append((relative, hit.text))
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                cache[url.path] = (modified, text)
                out.append((relative, text))
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return out
    }
}

final class WebhookIntegration: Integration {
    private let toolName: String
    private let description: String
    private let url: String
    private let method: String
    private let headers: [(String, String)]

    init(_ config: IntegrationConfig) {
        toolName = Slug.make(config.name, max: 50)
        description = config.notes.trimmed.isEmpty ? "Query \(config.name)." : config.notes.trimmed
        url = config.url.trimmed
        method = config.method.uppercased()
        headers = KeyValue.parse(config.headers, separator: ":")
    }

    func tools() async -> [ToolSpec] {
        url.isEmpty ? [] : [.query(toolName, description)]
    }

    func call(_ tool: String, _ args: JSON) async throws -> String {
        let query = args["query"]?.string ?? ""
        var request: URLRequest
        if method == "GET" {
            guard var parts = URLComponents(string: url) else { throw AppError("Bad URL") }
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "query", value: query)]
            guard let full = parts.url else { throw AppError("Bad URL") }
            request = URLRequest(url: full)
        } else {
            guard let target = URL(string: url) else { throw AppError("Bad URL") }
            request = URLRequest(url: target)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSON.object(["query": .string(query)]).data()
        }
        request.timeoutInterval = 15
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data.prefix(6000), as: UTF8.self)
        guard (200..<300).contains(status) else { throw AppError("HTTP \(status): \(body.prefix(300))") }
        return body.isEmpty ? "(empty response)" : body
    }
}

final class WebSearchIntegration: Integration {
    private let llm: OpenRouterClient
    private let modelOverride: String
    private let credentials: IntegrationHub.Credentials

    init(_ config: IntegrationConfig, llm: OpenRouterClient, credentials: @escaping IntegrationHub.Credentials) {
        self.llm = llm
        self.modelOverride = config.model.trimmed
        self.credentials = credentials
    }

    func tools() async -> [ToolSpec] {
        [.query("web_search", "Search the live web for current facts: news, scores, hours, prices, weather, events.", hint: "Search query")]
    }

    func call(_ tool: String, _ args: JSON) async throws -> String {
        let (key, model) = await credentials()
        let body: JSON = [
            "model": .string(modelOverride.isEmpty ? model : modelOverride),
            "messages": [
                ["role": "system", "content": "Answer the query concisely with concrete facts and dates. Mention source sites briefly."],
                ["role": "user", "content": .string(args["query"]?.string ?? "")],
            ],
            "plugins": [["id": "web", "max_results": 4]],
            "max_tokens": 500,
        ]
        let response = try await llm.chat(body, key: key)
        return response["choices"]?[0]?["message"]?["content"]?.string ?? "No results."
    }
}
