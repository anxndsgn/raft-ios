import SwiftUI
import UIKit

// MARK: Image cache

/// Decoded message images (thumbnails, Saved rows) in memory, evicted under pressure; one
/// download per URL at a time. Thumbnails (`cdn.raft.build/thumbs/…`) are unsigned and public.
@MainActor
final class RaftImageCache {
    static let shared = RaftImageCache()

    private let images = NSCache<NSURL, UIImage>()
    private var loads: [URL: Task<UIImage?, Never>] = [:]

    func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let image = image(for: url) { return image }
        if let load = loads[url] { return await load.value }
        let load = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        loads[url] = load
        let image = await load.value
        loads[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }

    #if DEBUG
    /// Preview gallery: a locally drawn image behind a made-up URL (nothing is downloaded).
    func debugSeed(_ image: UIImage, for url: URL) {
        images.setObject(image, forKey: url as NSURL)
    }
    #endif
}

// MARK: Layout (31a)

/// Sizes of the in-message images: the first at most 240 wide (height by its ratio, 120–320, 4:3
/// when unknown), the rest a two-column grid of 116×87 tiles, five at most.
enum MessageImageLayout {
    static let maxWidth: CGFloat = 240
    static let spacing: CGFloat = 8
    static let maxShown = 5
    static let tile = CGSize(width: (maxWidth - spacing) / 2, height: ((maxWidth - spacing) / 2) * 3 / 4)

    static func first(width: Int?, height: Int?, column: CGFloat) -> CGSize {
        let side = min(maxWidth, max(column, 1))
        guard let width, let height, width > 0, height > 0 else { return CGSize(width: side, height: side * 3 / 4) }
        let natural = side * CGFloat(height) / CGFloat(width)
        return CGSize(width: side, height: min(320, max(120, natural)))
    }

    /// The images shown (the first five).
    static func shown<T>(_ images: [T]) -> [T] { Array(images.prefix(maxShown)) }

    /// "+N" on the fifth tile: the images past the five shown (0 for none).
    static func overflow(count: Int) -> Int { max(0, count - maxShown) }

    /// Decodable by the system; other image types use `rasterPreviewUrl`.
    static func isDecodable(_ mimeType: String) -> Bool {
        let type = mimeType.lowercased()
        guard type.hasPrefix("image/") else { return false }
        return !["image/svg+xml", "image/x-adobe-dng", "image/x-canon-cr2", "image/x-nikon-nef", "image/vnd.adobe.photoshop", "image/x-icon"].contains(type)
    }

    /// What a tile draws: the thumbnail, else the raster preview of a type the system cannot
    /// draw; nil when only the signed original is left (fetched separately).
    static func thumbnailURL(_ attachment: MessageAttachment) -> URL? {
        if let url = Persona.httpURL(attachment.thumbnailUrl) { return url }
        if !isDecodable(attachment.mimeType), let url = Persona.httpURL(attachment.rasterPreviewUrl) { return url }
        return nil
    }
}

// MARK: Message images (31a)

/// A message's images: one large, then a grid; a tap opens the viewer at that image.
struct MessageImageGroup: View {
    let images: [MessageAttachment]
    let sender: Persona
    let date: Date?
    let store: AttachmentStore
    /// No viewer (lifted copy): the row's own open handler.
    var fallbackOpen: (MessageAttachment) -> Void = { _ in }
    var interactive = true

    /// Pixel size of the first image once loaded, for attachments that arrive without width/height
    /// (all of them, live): the 4:3 placeholder then takes the real ratio. The stream's scroll
    /// position is tracked by message id, so the visible message stays put while this row grows.
    @State private var loadedFirstSize: CGSize?

    private func firstSize(_ first: MessageAttachment) -> CGSize {
        if let w = first.width, let h = first.height, w > 0, h > 0 {
            return MessageImageLayout.first(width: w, height: h, column: MessageImageLayout.maxWidth)
        }
        let known = loadedFirstSize
            ?? MessageImageLayout.thumbnailURL(first).flatMap { RaftImageCache.shared.image(for: $0)?.size }
        return MessageImageLayout.first(
            width: known.map { Int($0.width.rounded()) },
            height: known.map { Int($0.height.rounded()) },
            column: MessageImageLayout.maxWidth
        )
    }

    var body: some View {
        let shown = MessageImageLayout.shown(images)
        VStack(alignment: .leading, spacing: MessageImageLayout.spacing) {
            if let first = shown.first {
                tile(first, index: 0, size: firstSize(first)) { image in
                    if loadedFirstSize == nil, first.width == nil || first.height == nil { loadedFirstSize = image.size }
                }
            }
            let rest = Array(shown.dropFirst())
            if !rest.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.fixed(MessageImageLayout.tile.width), spacing: MessageImageLayout.spacing), GridItem(.fixed(MessageImageLayout.tile.width))],
                    alignment: .leading,
                    spacing: MessageImageLayout.spacing
                ) {
                    ForEach(Array(rest.enumerated()), id: \.element.id) { offset, attachment in
                        let index = offset + 1
                        tile(attachment, index: index, size: MessageImageLayout.tile, overflow: index == MessageImageLayout.maxShown - 1 ? MessageImageLayout.overflow(count: images.count) : 0)
                    }
                }
                .frame(width: MessageImageLayout.maxWidth, alignment: .leading)
            }
        }
    }

    private func tile(_ attachment: MessageAttachment, index: Int, size: CGSize, overflow: Int = 0, onImage: @escaping (UIImage) -> Void = { _ in }) -> some View {
        MessageImageTile(
            attachment: attachment,
            index: index,
            count: images.count,
            size: size,
            overflow: overflow,
            store: store,
            interactive: interactive,
            onImage: onImage
        ) { viewer in
            if let viewer {
                viewer.open(images: images, at: index, sender: sender, date: date, attachments: store)
            } else {
                fallbackOpen(attachment)
            }
        }
    }
}

struct MessageImageTile: View {
    let attachment: MessageAttachment
    let index: Int
    let count: Int
    let size: CGSize
    var overflow = 0
    let store: AttachmentStore
    var interactive = true
    var onImage: (UIImage) -> Void = { _ in }
    let open: (ImageViewerModel?) -> Void

    @Environment(ImageViewerModel.self) private var viewer: ImageViewerModel?
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button {
            if failed {
                failed = false
                attempt += 1
            } else {
                open(viewer)
            }
        } label: {
            ZStack {
                Color.raftSkeleton
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.raftTextTertiary)
                }
                if overflow > 0 {
                    Color.raftInk.opacity(0.55)
                    Text(verbatim: L10n.f("ios_image_overflow", "+%1$d", overflow))
                        .font(.custom(RaftFont.bold, size: 20, relativeTo: .title3))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.18) : Color.raftInk.opacity(0.18), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(interactive)
        // The viewer flies out of (and back into) this frame; hidden while it shows this image.
        .opacity(viewer?.hiddenAttachmentId == attachment.id ? 0 : 1)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            if interactive { viewer?.noteSource(frame, for: attachment.id) }
        }
        .accessibilityLabel(Text(verbatim: a11yLabel))
        .accessibilityHint(failed ? Text(L10n.t("common_retry", "Retry")) : Text(L10n.t("ios_image_open_hint", "Opens image viewer")))
        .accessibilityAddTraits(.isImage)
        .task(id: "\(attachment.id)#\(attempt)") { await load() }
        #if DEBUG
        .task {
            // Preview gallery 31, 31c, 31d: the viewer opens out of 31a's store hero.
            guard let screen = PreviewGallery.screen, ["31", "31c", "31d"].contains(screen), interactive, attachment.id == "img-hero" else { return }
            try? await Task.sleep(for: .milliseconds(700))
            open(viewer)
        }
        #endif
    }

    private var a11yLabel: String {
        let counter = L10n.f("image_lightbox_counter", "%1$d of %2$d", index + 1, count)
        var parts = ["\(L10n.t("ios_image", "Image")) \(counter)"]
        if !attachment.filename.isEmpty { parts.append(attachment.filename) }
        return parts.joined(separator: ", ")
    }

    private func load() async {
        var url = MessageImageLayout.thumbnailURL(attachment)
        if let cached = url.flatMap({ RaftImageCache.shared.image(for: $0) }) {
            image = cached
            onImage(cached)
            viewer?.noteThumbnail(cached, for: attachment.id)
            return
        }
        if url == nil { url = try? await store.url(for: attachment.id) }
        guard let url, let loaded = await RaftImageCache.shared.load(url) else {
            failed = true
            return
        }
        image = loaded
        onImage(loaded)
        viewer?.noteThumbnail(loaded, for: attachment.id)
    }
}
