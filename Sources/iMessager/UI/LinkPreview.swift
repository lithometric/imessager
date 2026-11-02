import AppKit
import LinkPresentation
import SwiftUI

/// Title, site and icon for a link, fetched once per URL and kept in memory.
@MainActor @Observable
final class LinkPreviews {
    static let shared = LinkPreviews()

    struct Preview {
        let title: String?
        let host: String
        var icon: NSImage?
    }

    private(set) var cache: [URL: Preview] = [:]
    private var loading: Set<URL> = []

    func load(_ url: URL) async {
        guard cache[url] == nil, loading.insert(url).inserted else { return }
        defer { loading.remove(url) }
        let host = (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let provider = LPMetadataProvider()
        provider.timeout = 6
        guard let meta = try? await provider.startFetchingMetadata(for: url) else {
            cache[url] = Preview(title: nil, host: host)
            return
        }
        let title = meta.title
        let iconProvider = meta.iconProvider ?? meta.imageProvider
        cache[url] = Preview(title: title, host: host)
        if let iconProvider {
            let data = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
                iconProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in done.resume(returning: data) }
            }
            if let data, let image = NSImage(data: data) { cache[url]?.icon = image }
        }
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
        .help(url.absoluteString)
        .task(id: url) { await LinkPreviews.shared.load(url) }
    }
}
