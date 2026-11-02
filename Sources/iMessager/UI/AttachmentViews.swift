import AppKit
import AVFoundation
import AVKit
import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A photo, video or file in a thread, like Messages: photos and videos as rounded previews, everything else as a chip.
/// Click to open, drag it out to Finder, right-click to copy or show in Finder.
struct AttachmentView: View {
    let url: URL
    let name: String
    let isImage: Bool
    let isVideo: Bool
    /// Double-clicking a photo or video opens it in iMessager's viewer; other files open in their app.
    var onOpen: ((URL) -> Void)?
    @State private var thumb: NSImage?

    init(_ attachment: Attachment, onOpen: ((URL) -> Void)? = nil) {
        url = URL(fileURLWithPath: attachment.path)
        name = attachment.name
        isImage = attachment.isImage
        isVideo = attachment.isVideo
        self.onOpen = onOpen
    }

    init(file url: URL, onOpen: ((URL) -> Void)? = nil) {
        let type = UTType(filenameExtension: url.pathExtension)
        self.url = url
        name = url.lastPathComponent
        isImage = type?.conforms(to: .image) ?? false
        isVideo = type?.conforms(to: .movie) ?? false
        self.onOpen = onOpen
    }

    var body: some View {
        Group {
            if isImage || isVideo {
                media
            } else {
                chip
            }
        }
        .onTapGesture(count: 2) {
            if isImage || isVideo, let onOpen { onOpen(url) } else { NSWorkspace.shared.open(url) }
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(name)
    }

    private var media: some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        // The box is sized before the preview loads (from the file header), so the thread doesn't shift as photos appear.
        let size = Thumbnails.displaySize(url, video: isVideo)
        return Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
            } else if FileManager.default.fileExists(atPath: url.path) {
                shape.fill(Color.primary.opacity(0.07)).frame(width: size.width, height: size.height).shimmering()
            } else {
                // Not on this Mac yet (still downloading, or kept in iCloud).
                VStack(spacing: 6) {
                    Image(systemName: isVideo ? "video" : "photo").font(.title2)
                    Text("Not downloaded").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(width: 200, height: 150)
                .background(Color.primary.opacity(0.07), in: shape)
            }
        }
        .clipShape(shape)
        .overlay {
            if isVideo, thumb != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .liquidGlass(in: Circle())
            }
        }
        .task(id: url) { thumb = await Thumbnails.load(url, video: isVideo) }
    }

    private var chip: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(sizeText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sizeText: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Not downloaded"
    }
}

/// A photo or video, big, over the blurred conversation (like Messages). Click outside or press Esc to close.
struct MediaViewer: View {
    let url: URL
    let close: () -> Void
    @State private var image: NSImage?
    @State private var player: AVPlayer?

    private var isVideo: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.5))
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            Group {
                if isVideo, let player {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ProgressView()
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
            .padding(.horizontal, 48)
            .padding(.vertical, 64)
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        }
        .overlay(alignment: .topTrailing) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 18, height: 18) }
                        .glassCircleButton()
                        .help("Share")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Image(systemName: "folder").frame(width: 18, height: 18)
                    }
                    .glassCircleButton()
                    .help("Show in Finder")
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 18, height: 18)
                    }
                    .glassCircleButton()
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                }
            }
            .padding(16)
        }
        .task(id: url) {
            if isVideo {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            } else {
                let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
                image = data.flatMap(NSImage.init(data:))
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// Right-click items every attachment gets.
struct AttachmentActions: View {
    let url: URL

    var body: some View {
        Button("Open") { NSWorkspace.shared.open(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy") {
            let pb = NSPasteboard.general
            pb.clearContents()
            var items: [NSPasteboardWriting] = [url as NSURL]
            if let image = NSImage(contentsOf: url) { items.append(image) }
            pb.writeObjects(items)
        }
    }
}

/// Small preview in the composer tray, with a remove button.
struct AttachmentChip: View {
    let url: URL
    let remove: () -> Void
    @State private var thumb: NSImage?

    var body: some View {
        let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().padding(10)
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove")
        }
        .help(url.lastPathComponent)
        .task(id: url) { thumb = await Thumbnails.load(url, video: isVideo) }
    }
}

/// Decoded previews, made off the main thread and kept in memory.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()
    private static var sizes: [URL: CGSize] = [:]

    /// On-screen size for a photo (fit within 260 × 320, from its header, no decoding) or a video (fixed square).
    static func displaySize(_ url: URL, video: Bool) -> CGSize {
        if let hit = sizes[url] { return hit }
        var size = CGSize(width: 220, height: 220)
        if !video, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           var w = props[kCGImagePropertyPixelWidth] as? CGFloat, var h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
            if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&w, &h) }
            let scale = min(260 / w, 320 / h, 1)
            size = CGSize(width: max(80, (w * scale).rounded()), height: max(60, (h * scale).rounded()))
        }
        sizes[url] = size
        return size
    }

    static func load(_ url: URL, video: Bool) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let cg: CGImage?
        if video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            cg = try? await generator.image(at: .zero).image
        } else {
            cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 640]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
        }
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// A photo or video chosen in the Photos picker, copied to `Staging` so Messages can send it.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { PickedFile(url: try Staging.stage($0.file)) }
        FileRepresentation(importedContentType: .image) { PickedFile(url: try Staging.stage($0.file)) }
    }
}

/// Turning pasted or dropped things into staged files.
enum Incoming {
    /// Files and images on the pasteboard, or nil if it's just text (so normal text paste happens).
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [URL]? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap { try? Staging.stage($0) }
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                                         NSPasteboard.PasteboardType("public.heic")]
        guard let type = pb.availableType(from: imageTypes), let data = pb.data(forType: type) else { return nil }
        // Copying from a browser puts both text and an image on the pasteboard; Messages pastes the image.
        let png: Data? = type == .png ? data
            : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        guard let png, let url = try? Staging.stage(png, name: "Pasted Image.png") else { return nil }
        return [url]
    }

    /// Dropped files, or image data from apps that don't drag files (browsers, Photos).
    static func fromDrop(_ providers: [NSItemProvider], into add: @escaping @MainActor (URL) -> Void) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let staged = try? Staging.stage(url) else { return }
                    Task { @MainActor in add(staged) }
                }
            } else if let type = [UTType.movie, .image].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                handled = true
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    guard let url, let staged = try? Staging.stage(url) else { return }
                    Task { @MainActor in add(staged) }
                }
            }
        }
        return handled
    }
}
