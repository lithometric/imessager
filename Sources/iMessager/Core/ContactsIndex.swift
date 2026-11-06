import Contacts
import Foundation

/// In-memory handle → name map built from the Contacts app. chat.db stores numbers, not names.
final class ContactsIndex: @unchecked Sendable {
    private let store = CNContactStore()
    private let lock = NSLock()
    private var phones: [String: String] = [:]
    private var emails: [String: String] = [:]
    private var ids: [String: String] = [:]          // phone key / email → contact identifier
    private var entries: [Entry] = []                // every name + number/email, for the To: field

    /// One way to reach someone: a contact's name with one of their numbers or emails.
    struct Entry: Codable, Hashable, Sendable, Identifiable {
        let name: String
        let handle: String
        let label: String
        var company: String? = nil
        var jobTitle: String? = nil
        var id: String { handle }
    }

    /// Everyone in Contacts, one per name, with where they work (for the command bar's "anyone at…" requests).
    struct Person: Sendable {
        let name: String
        let company: String?
        let jobTitle: String?
        let handles: [String]
    }
    private var photos: [String: Photo?] = [:]       // contact identifier → photo data

    /// `cropped` is the thumbnail with the crop you chose in Contacts; `original` is the full uncropped image.
    struct Photo: Sendable {
        let cropped: Data?
        let original: Data?
    }

    static var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }
    var authorized: Bool { Self.status == .authorized }

    /// Last index, saved after each reload so names show instantly on the next launch (rebuildable; it's a cache).
    private struct Snapshot: Codable {
        var phones: [String: String]
        var emails: [String: String]
        var ids: [String: String]
        var entries: [Entry]?
    }

    static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.lithometric.imessager", isDirectory: true)
    private static var snapshotURL: URL { cacheDirectory.appendingPathComponent("contacts-index.json") }

    init() {
        guard authorized, let data = try? Data(contentsOf: Self.snapshotURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        phones = snap.phones
        emails = snap.emails
        ids = snap.ids
        entries = snap.entries ?? []
    }

    func requestAccess() async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Blocking; call off the main thread.
    func reload() {
        guard authorized else { return }
        var p: [String: String] = [:]
        var e: [String: String] = [:]
        var i: [String: String] = [:]
        var list: [Entry] = []
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                    CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
                    CNContactImageDataAvailableKey] as [CNKeyDescriptor]
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let name = Self.displayName(contact)
            guard !name.isEmpty else { return }
            let company = contact.organizationName.trimmed.isEmpty ? nil : contact.organizationName.trimmed
            let jobTitle = contact.jobTitle.trimmed.isEmpty ? nil : contact.jobTitle.trimmed
            for number in contact.phoneNumbers {
                let key = Self.phoneKey(number.value.stringValue)
                guard !key.isEmpty else { continue }
                p[key] = name
                if contact.imageDataAvailable { i[key] = contact.identifier }
                list.append(Entry(name: name, handle: number.value.stringValue, label: Self.label(number.label, fallback: "phone"),
                                  company: company, jobTitle: jobTitle))
            }
            for email in contact.emailAddresses {
                let key = (email.value as String).lowercased()
                e[key] = name
                if contact.imageDataAvailable { i[key] = contact.identifier }
                list.append(Entry(name: name, handle: email.value as String, label: Self.label(email.label, fallback: "email"),
                                  company: company, jobTitle: jobTitle))
            }
        }
        lock.withLock {
            phones = p
            emails = e
            ids = i
            entries = list
            photos = [:]
        }
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Snapshot(phones: p, emails: e, ids: i, entries: list)).write(to: Self.snapshotURL, options: .atomic)
    }

    /// The contact's photo, fetched on first use. Blocking; call off the main thread.
    func photo(for handle: String) -> Photo? {
        let key = handle.contains("@") ? handle.lowercased() : Self.phoneKey(handle)
        guard let id = lock.withLock({ ids[key] }) else { return nil }
        if let cached = lock.withLock({ photos[id] }) { return cached }
        let keys = [CNContactImageDataKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys)
        let photo = contact.map { Photo(cropped: $0.thumbnailImageData, original: $0.imageData) }
        lock.withLock { photos[id] = .some(photo) }
        return photo
    }

    /// Contacts matching what's typed in the To: field: names by word prefix, numbers by digits, emails by text.
    func search(_ query: String, limit: Int = 40) -> [Entry] {
        let q = query.trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        let digits = q.filter(\.isNumber)
        let all = lock.withLock { entries }
        let hits = all.filter { entry in
            let name = entry.name.lowercased()
            if name.hasPrefix(q) || name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return true }
            if digits.count >= 3, entry.handle.filter(\.isNumber).contains(digits) { return true }
            return entry.handle.contains("@") && entry.handle.lowercased().contains(q)
        }
        return Array(hits.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.prefix(limit))
    }

    /// People whose name, company, job title, number or email contains `query` (everyone when it's empty).
    func people(matching query: String = "", withCompanyOnly: Bool = false) -> [Person] {
        let q = query.trimmed.lowercased()
        var order: [String] = []
        var byName: [String: (company: String?, title: String?, handles: [String])] = [:]
        for entry in lock.withLock({ entries }) {
            if byName[entry.name] == nil { order.append(entry.name) }
            var person = byName[entry.name] ?? (entry.company, entry.jobTitle, [])
            person.handles.append(entry.handle)
            byName[entry.name] = person
        }
        return order.compactMap { name in
            guard let p = byName[name] else { return nil }
            let domains = p.handles.compactMap { $0.split(separator: "@").last.map(String.init) }.filter { $0.contains(".") }
            if withCompanyOnly, p.company == nil, domains.allSatisfy(Self.personalDomains.contains) { return nil }
            if !q.isEmpty {
                let haystack = ([name, p.company ?? "", p.title ?? ""] + p.handles).joined(separator: " ").lowercased()
                let digits = q.filter(\.isNumber)
                guard haystack.contains(q) || (digits.count >= 4 && haystack.filter(\.isNumber).contains(digits)) else { return nil }
            }
            return Person(name: name, company: p.company, jobTitle: p.title, handles: p.handles)
        }
    }

    /// Email providers that say nothing about where someone works.
    private static let personalDomains: Set<String> = [
        "gmail.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "hotmail.com", "outlook.com", "live.com", "aol.com",
        "protonmail.com", "proton.me", "msn.com", "comcast.net", "att.net", "verizon.net",
    ]

    /// Messages' form of a handle: "+15551234567" for numbers, lowercase for emails.
    static func normalized(_ handle: String) -> String {
        let h = handle.trimmed
        if h.contains("@") { return h.lowercased() }
        let digits = h.filter(\.isNumber)
        if h.hasPrefix("+") { return "+" + digits }
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return digits
    }

    static func sameHandle(_ a: String, _ b: String) -> Bool {
        if a.contains("@") || b.contains("@") { return a.lowercased() == b.lowercased() }
        let ka = phoneKey(a), kb = phoneKey(b)
        return !ka.isEmpty && ka == kb
    }

    private static func label(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw).lowercased()
    }

    func name(for handle: String) -> String? {
        lock.withLock {
            handle.contains("@") ? emails[handle.lowercased()] : phones[Self.phoneKey(handle)]
        }
    }

    func save(name: String, handle: String) throws {
        let contact = CNMutableContact()
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.first ?? name
        if parts.count > 1 { contact.familyName = parts[1] }
        if handle.contains("@") {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: handle as NSString)]
        } else {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: handle))]
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try store.execute(request)
        lock.withLock {
            if handle.contains("@") { emails[handle.lowercased()] = name } else { phones[Self.phoneKey(handle)] = name }
        }
    }

    /// Last 10 digits, so "+1 (555) 010-2030" and "5550102030" match.
    static func phoneKey(_ s: String) -> String {
        String(s.filter(\.isNumber).suffix(10))
    }

    static func displayName(_ c: CNContact) -> String {
        let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        if !c.nickname.isEmpty { return c.nickname }
        return c.organizationName
    }

    static func pretty(_ handle: String) -> String {
        guard !handle.contains("@") else { return handle }
        let d = handle.filter(\.isNumber)
        if d.count == 11, d.hasPrefix("1") {
            let a = Array(d)
            return "+1 (\(String(a[1...3]))) \(String(a[4...6]))-\(String(a[7...10]))"
        }
        if d.count == 10 {
            let a = Array(d)
            return "(\(String(a[0...2]))) \(String(a[3...5]))-\(String(a[6...9]))"
        }
        return handle
    }
}
