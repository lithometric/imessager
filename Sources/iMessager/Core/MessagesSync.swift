import AppKit
import ApplicationServices

/// Keeps Messages' read state in step with iMessager by pressing Messages' own "Mark as Read" / "Mark as Unread"
/// on the conversation's row, through Accessibility (Messages has no other way for apps to do this).
/// Needs Accessibility permission, Messages open, and the conversation in its sidebar list (recent ones are;
/// Messages' pinned conversations don't offer these actions).
/// Like reading on your phone, marking read can send a read receipt if you have those turned on.
enum MessagesSync {
    static var allowed: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    enum Outcome: Equatable { case marked, alreadyThatWay, notFound, notAllowed, messagesClosed }

    /// `names`: how the conversation may be titled in Messages (contact name, group name, formatted number).
    /// With `perform: false` it only looks (for testing).
    @discardableResult
    static func mark(names: [String], read: Bool, perform: Bool = true) -> Outcome {
        guard allowed else { return .notAllowed }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { return .messagesClosed }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        let wanted = read ? "mark as read" : "mark as unread"
        let opposite = read ? "mark as unread" : "mark as read"
        let targets = names.map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }

        for window in (value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            for row in descendants(window) {
                let actions = actionNames(row)
                guard let action = actions.first(where: { $0.lowercased().contains(wanted) })
                        ?? actions.first(where: { $0.lowercased().contains(opposite) }) else { continue }
                // A row reads "Name, preview, time"; match the name exactly so "Beshoy" doesn't hit "Beshoy & Arooba".
                let label = ((value(row, kAXDescriptionAttribute) as? String) ?? texts(row).first ?? "").lowercased()
                let leading = label.components(separatedBy: ",").prefix(2).map { $0.trimmed }
                guard leading.contains(where: { targets.contains($0) }) else { continue }
                guard action.lowercased().contains(wanted) else { return .alreadyThatWay }
                if perform { AXUIElementPerformAction(row, action as CFString) }
                return .marked
            }
        }
        return .notFound
    }

    // MARK: - Accessibility helpers

    private static func value(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, attribute as CFString, &v)
        return v
    }

    private static func actionNames(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return (names as? [String]) ?? []
    }

    private static func descendants(_ e: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 30 else { return [] }
        let children = (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        return [e] + children.flatMap { descendants($0, depth: depth + 1) }
    }

    /// Visible text in a row, top to bottom.
    private static func texts(_ e: AXUIElement) -> [String] {
        descendants(e).compactMap { el -> String? in
            guard (value(el, kAXRoleAttribute) as? String) == "AXStaticText" else { return nil }
            let text = ((value(el, kAXValueAttribute) as? String) ?? (value(el, kAXDescriptionAttribute) as? String) ?? "").trimmed
            return text.isEmpty ? nil : text
        }
    }
}
