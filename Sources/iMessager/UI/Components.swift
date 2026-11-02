import SwiftUI

enum Theme {
    static let sidebarWidth: CGFloat = 330      // the conversation list, Messages' width
    static let sidebarMinWidth: CGFloat = 290   // where it stops when you drag it narrower
    static let sidebarMaxWidth: CGFloat = 460
    static let contentMaxWidth: CGFloat = 720
    static let padding: CGFloat = 24
    static let radius: CGFloat = 12
    static let minWindow = CGSize(width: 860, height: 600)
    /// Height of the glass toolbar row the traffic lights sit in.
    static let headerHeight: CGFloat = 52
}

/// Scrolling page with a centered, width-capped column so wide windows stay tidy.
struct Page<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header()
                content()
            }
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .padding(Theme.padding)
            .frame(maxWidth: .infinity)
        }
    }
}


/// One-line intro under the toolbar title, with optional trailing controls.
struct PageIntro<Trailing: View>: View {
    let text: String
    let trailing: () -> Trailing

    init(_ text: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension PageIntro where Trailing == EmptyView {
    init(_ text: String) {
        self.text = text
        self.trailing = { EmptyView() }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .liquidGlass(in: Capsule(), interactive: true)
    }
}

/// Small rounded label, e.g. "NEW" or "Required".
struct Tag: View {
    let text: String
    var tint: Color = .accentColor

    init(_ text: String, tint: Color = .accentColor) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Liquid Glass (macOS 26), with material fallbacks for macOS 14–15
// Glass is for controls that float above content (composer, search, notices, toolbar), never for the messages themselves.

extension View {
    @ViewBuilder
    func liquidGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08)))
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Round glass icon button, e.g. the composer's draft and send buttons.
    func glassCircleButton(prominent: Bool = false) -> some View {
        glassButtonStyle(prominent: prominent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }

    @ViewBuilder
    func softScrollEdge(_ edges: Edge.Set) -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: edges) } else { self }
    }

    /// A bar that content scrolls underneath (with the soft scroll-edge blur on macOS 26).
    @ViewBuilder
    func floatingBar<Bar: View>(_ edge: VerticalEdge, @ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: edge, spacing: 0, content: bar)
        }
    }
}

/// Lets neighbouring glass shapes blend and morph into each other.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

// MARK: - Loading

/// A soft highlight sweeping across placeholder shapes while content loads.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: phase * geo.size.width * 1.4)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// Placeholder conversation rows.
struct ListSkeleton: View {
    var body: some View {
        VStack(spacing: 18) {
            ForEach(0..<9, id: \.self) { i in
                HStack(spacing: 10) {
                    Circle().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().frame(width: [120, 90, 140, 105][i % 4], height: 10)
                        Capsule().frame(height: 8)
                        Capsule().frame(width: [150, 120, 170, 90][i % 4], height: 8)
                    }
                }
            }
        }
        .foregroundStyle(Color.primary.opacity(0.07))
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .shimmering()
    }
}

/// Placeholder bubbles while a thread loads.
struct TranscriptSkeleton: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<8, id: \.self) { i in
                let mine = [false, true, false, false, true, true, false, true][i]
                HStack {
                    if mine { Spacer() }
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(mine ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.08))
                        .frame(width: [180, 240, 120, 300, 160, 210, 260, 140][i], height: [34, 34, 34, 50, 34, 34, 50, 34][i])
                    if !mine { Spacer() }
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .shimmering()
    }
}

// MARK: - Links

enum Linkify {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    final class Result {
        let attributed: AttributedString
        let url: URL?
        init(_ attributed: AttributedString, _ url: URL?) {
            self.attributed = attributed
            self.url = url
        }
    }

    private static let memo: NSCache<NSString, Result> = {
        let cache = NSCache<NSString, Result>()
        cache.countLimit = 2000
        return cache
    }()

    /// Link detection runs once per message text, not on every redraw of a thread.
    static func cached(_ text: String) -> Result {
        if let hit = memo.object(forKey: text as NSString) { return hit }
        let result = Result(attributed(text), firstWebURL(text))
        memo.setObject(result, forKey: text as NSString)
        return result
    }

    /// Message text with web, email and phone links attached and underlined.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for (url, range) in matches(text) {
            guard let r = Range(range, in: out) else { continue }
            out[r].link = url
            out[r].underlineStyle = .single
        }
        return out
    }

    static func firstWebURL(_ text: String) -> URL? {
        matches(text).first { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }?.url
    }

    private static func matches(_ text: String) -> [(url: URL, range: Range<String.Index>)] {
        guard let detector, text.contains(where: { $0 == "." || $0 == ":" || $0 == "@" }) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let url = m.url, let range = Range(m.range, in: text) else { return nil }
            return (url, range)
        }
    }
}
