import AppKit
import LinkPresentation
import SwiftUI

/// Title, site and icon for a link, fetched once per URL. Kept in memory and on disk, so a link that's been seen
/// opens at its full size instead of growing (and moving the conversation) as its picture arrives.
@MainActor @Observable
final class LinkPreviews {
    static let shared = LinkPreviews()

    struct Preview {
        let title: String?
        let host: String
        var icon: NSImage?
        /// The page's main picture (album art, article image…), and its average color for the caption strip.
        var image: NSImage?
        var tint: NSColor?
    }

    private(set) var cache: [URL: Preview] = [:]
    private var loading: Set<URL> = []

    func load(_ url: URL) async {
        guard cache[url] == nil, loading.insert(url).inserted else { return }
        defer { loading.remove(url) }
        if let saved = await Self.read(url) {
            cache[url] = saved
            return
        }
        let host = (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let provider = LPMetadataProvider()
        provider.timeout = 6
        guard let meta = try? await provider.startFetchingMetadata(for: url) else {
            cache[url] = Preview(title: nil, host: host)
            return
        }
        cache[url] = Preview(title: meta.title, host: host)
        var imageData: Data?
        var iconData: Data?
        if let provider = meta.imageProvider, let data = await Self.data(provider), let image = NSImage(data: data) {
            imageData = data
            cache[url]?.image = image
            cache[url]?.tint = Self.averageColor(image)
        }
        if let provider = meta.iconProvider, let data = await Self.data(provider), let image = NSImage(data: data) {
            iconData = data
            cache[url]?.icon = image
        }
        let tint = cache[url]?.tint?.usingColorSpace(.sRGB).map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)] }
        let saved = Saved(title: meta.title, host: host, tint: tint)
        Task.detached(priority: .utility) { Self.write(url, saved, image: imageData, icon: iconData) }
    }

    /// Loads the saved previews for these links (disk only, no network), so they're ready before the thread shows.
    func warm(_ urls: [URL]) {
        for url in urls where cache[url] == nil && !loading.contains(url) {
            loading.insert(url)
            Task {
                if let saved = await Self.read(url), cache[url] == nil { cache[url] = saved }
                loading.remove(url)
            }
        }
    }

    // MARK: Disk (~/Library/Caches/com.lithometric.imessager/link-previews)

    private struct Saved: Codable, Sendable {
        let title: String?
        let host: String
        let tint: [Double]?
    }

    nonisolated private static var directory: URL {
        ContactsIndex.cacheDirectory.appendingPathComponent("link-previews", isDirectory: true)
    }

    nonisolated private static func file(_ url: URL, _ suffix: String) -> URL {
        let hash = url.absoluteString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return directory.appendingPathComponent(String(hash, radix: 36) + suffix)
    }

    nonisolated private static func write(_ url: URL, _ saved: Saved, image: Data?, icon: Data?) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let image { try? image.write(to: file(url, ".image"), options: .atomic) }
        if let icon { try? icon.write(to: file(url, ".icon"), options: .atomic) }
        try? JSONEncoder().encode(saved).write(to: file(url, ".json"), options: .atomic)
    }

    private static func read(_ url: URL) async -> Preview? {
        let stored = await Task.detached(priority: .userInitiated) { () -> (Saved, Data?, Data?)? in
            guard let data = try? Data(contentsOf: file(url, ".json")),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
            return (saved, try? Data(contentsOf: file(url, ".image")), try? Data(contentsOf: file(url, ".icon")))
        }.value
        guard let (saved, image, icon) = stored else { return nil }
        var preview = Preview(title: saved.title, host: saved.host)
        preview.image = image.flatMap(NSImage.init(data:))
        preview.icon = icon.flatMap(NSImage.init(data:))
        if let t = saved.tint, t.count == 3 { preview.tint = NSColor(srgbRed: t[0], green: t[1], blue: t[2], alpha: 1) }
        return preview
    }

    private static func data(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in done.resume(returning: data) }
        }
    }

    /// Messages tints a rich link's caption with the picture's colors; the average is a close match.
    private static func averageColor(_ image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let px = raw.assumingMemoryBound(to: UInt8.self)
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

/// A message that's just a link, shown the way Messages does: the page's picture with its title and site underneath,
/// in place of the URL. Without a picture it's a compact card with the site's icon.
struct RichLinkBubble: View {
    let url: URL
    let fromMe: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        let preview = LinkPreviews.shared.cache[url]
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        let tint = preview?.tint.map(Color.init(nsColor:))
        let dark = preview?.tint.map { $0.luminance < 0.55 } ?? true
        Button {
            openURL(url)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image = preview?.image {
                    // The whole picture at the card's width, like Messages; only a very tall one is cropped.
                    let size = image.size
                    let height = size.width > 0 ? min(340, max(56, 280 * size.height / size.width)) : 200
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: 280, height: height)
                        .clipped()
                }
                HStack(spacing: 10) {
                    if preview?.image == nil {
                        Group {
                            if let icon = preview?.icon {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "safari").font(.system(size: 16)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preview?.title ?? preview?.host ?? url.host() ?? url.absoluteString)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(preview?.host ?? url.host() ?? "")
                            .font(.system(size: 11))
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(preview?.image != nil ? (dark ? Color.white : Color.black) : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: 280, alignment: .leading)
                .background(preview?.image != nil ? (tint ?? Color.primary.opacity(0.1)) : Color.primary.opacity(0.08))
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
            .overlay { if preview == nil { shape.fill(Color.primary.opacity(0.05)).shimmering() } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .task(id: url) { await LinkPreviews.shared.load(url) }
    }
}

private extension NSColor {
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

/// Compact card under a message with a link, like Messages' rich links.
struct LinkPreviewCard: View {
    let url: URL
    let fromMe: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        let preview = LinkPreviews.shared.cache[url]
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let icon = preview?.icon {
                        Image(nsImage: icon).resizable().scaledToFill()
                    } else {
                        Image(systemName: "safari").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.title ?? url.absoluteString)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(preview?.host ?? url.host() ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 280)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if preview == nil {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)).shimmering()
            }
        }
        .task(id: url) { await LinkPreviews.shared.load(url) }
    }
}
