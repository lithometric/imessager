import Foundation

/// Conversations pinned in Messages. Messages keeps them in its own preferences (synced over iCloud), not in chat.db.
/// Every string in that plist is matched against chat identifiers, so small format changes across macOS versions don't matter.
/// Conversations muted in Messages ("Hide Alerts"); iMessager doesn't notify for them either.
enum Muted {
    static let path = NSHomeDirectory() + "/Library/Preferences/com.apple.MobileSMS.CKDNDList.plist"

    static func load() -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [] }
        var out: [String] = []
        Pins.collect(plist, into: &out)
        return out
    }
}

enum Pins {
    static let path = NSHomeDirectory() + "/Library/Preferences/com.apple.messages.pinning.plist"

    /// Identifiers in pin order. Needs Full Disk Access, like chat.db.
    static func load() -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [] }
        var out: [String] = []
        collect(plist, into: &out)
        return out
    }

    /// Pin position for a chat, matching phone numbers loosely ("+1 555…" vs "555…").
    /// Groups are pinned by their group id, people by number or email.
    static func order(of chat: (id: String, guid: String, groupID: String?), in pins: [String]) -> Int? {
        let phone = chat.id.contains("@") ? nil : ContactsIndex.phoneKey(chat.id)
        return pins.firstIndex { pin in
            pin == chat.id || pin == chat.guid || pin.hasSuffix(";" + chat.id)
                || (chat.groupID.map { !$0.isEmpty && pin.localizedCaseInsensitiveContains($0) } ?? false)
                || (phone.map { $0.count >= 7 && !pin.contains("@") && ContactsIndex.phoneKey(pin) == $0 } ?? false)
        }
    }

    static func collect(_ value: Any, into out: inout [String]) {
        switch value {
        case let s as String where !s.isEmpty && !out.contains(s): out.append(s)
        case let a as [Any]: a.forEach { collect($0, into: &out) }
        case let d as [String: Any]:
            for key in d.keys.sorted() {
                if !out.contains(key) { out.append(key) }
                collect(d[key]!, into: &out)
            }
        default: break
        }
    }
}
