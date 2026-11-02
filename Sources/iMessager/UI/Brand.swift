import AppKit
import SwiftUI

/// The imessager logo, generated from Support/Brand/imessager-brand.png by scripts/make-brand.py.
enum Brand {
    /// Blue from the app icon.
    static let blue = Color(red: 36 / 255, green: 131 / 255, blue: 242 / 255)

    static let menuBar = image("MenuBarIcon")

    /// The mark of the AI writing replies, as a template (tinted by `providerColor`).
    static func providerLogo(_ provider: AIProvider, large: Bool = false) -> NSImage? {
        let name = switch provider {
        case .claudeCode: "Logo-claude"
        case .openRouter: "Logo-openrouter"
        }
        return image(large ? name + "-64" : name)
    }

    /// Claude's terracotta; OpenRouter (and OpenAI's ChatGPT mark, if that provider is added) use the text color.
    static func providerColor(_ provider: AIProvider) -> Color {
        provider == .claudeCode ? Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) : .primary
    }
    static let bubble = image("Bubble")
    static let wordmark = image("Wordmark")

    /// Templates, so they take whatever color they're given (and the menu bar's own light/dark ink).
    private static func image(_ name: String) -> NSImage? {
        guard let image = Bundle.main.image(forResource: name) else { return nil }
        image.isTemplate = true
        return image
    }
}

/// Bubble + "imessager", as on the brand sheet: blue bubble and black text in light mode, all white in dark mode.
struct BrandLockup: View {
    var height: CGFloat = 20
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: height * 0.32) {
            if let bubble = Brand.bubble {
                Image(nsImage: bubble)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: height * 1.25, height: height * 1.25)
                    .foregroundStyle(scheme == .dark ? Color.white : Brand.blue)
            }
            if let wordmark = Brand.wordmark {
                Image(nsImage: wordmark)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
                    .foregroundStyle(.primary)
            } else {
                Text("imessager").font(.system(size: height, weight: .bold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("imessager")
    }
}
