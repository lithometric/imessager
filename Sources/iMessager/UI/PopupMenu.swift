import AppKit

/// A plain menu shown at the pointer, for glass buttons that should look like buttons (SwiftUI's Menu draws differently).
@MainActor
enum PopupMenu {
    static func show(_ items: [(title: String, symbol: String, action: () -> Void)]) {
        let menu = NSMenu()
        for item in items {
            let entry = ClosureItem(title: item.title, action: item.action)
            entry.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class ClosureItem: NSMenuItem {
        private let handler: () -> Void

        init(title: String, action: @escaping () -> Void) {
            handler = action
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError("not used") }

        @objc private func run() { handler() }
    }
}
