import SwiftUI
import UIKit

/// The full-screen image viewer's state (31): which message's images are open, at which one,
/// and where their thumbnails sit in the conversation (the viewer flies out of and back into
/// them). One per main screen, in the environment.
@MainActor
@Observable
final class ImageViewerModel {
    struct Session: Identifiable {
        let id = UUID()
        let images: [MessageAttachment]
        let start: Int
        let sender: Persona
        let date: Date?
        let attachments: AttachmentStore
    }

    private(set) var session: Session?
    /// The page shown (its thumbnail in the conversation is hidden meanwhile).
    var current = 0

    @ObservationIgnored private var sources: [String: CGRect] = [:]
    @ObservationIgnored private var thumbnails: [String: UIImage] = [:]

    var hiddenAttachmentId: String? {
        guard let session, session.images.indices.contains(current) else { return nil }
        return session.images[current].id
    }

    func open(images: [MessageAttachment], at index: Int, sender: Persona, date: Date?, attachments: AttachmentStore) {
        guard !images.isEmpty, session == nil else { return }
        let start = min(max(index, 0), images.count - 1)
        current = start
        session = Session(images: images, start: start, sender: sender, date: date, attachments: attachments)
    }

    /// After the close animation.
    func dismiss() {
        session = nil
    }

    func noteSource(_ frame: CGRect, for id: String) {
        sources[id] = frame
    }

    func source(for id: String) -> CGRect? { sources[id] }

    func noteThumbnail(_ image: UIImage, for id: String) {
        thumbnails[id] = image
    }

    func thumbnail(for attachment: MessageAttachment) -> UIImage? {
        if let image = thumbnails[attachment.id] { return image }
        return MessageImageLayout.thumbnailURL(attachment).flatMap { RaftImageCache.shared.image(for: $0) }
    }
}

/// Swipe-down to close (31, the old client's `RaftImageViewerSwipeDismiss.kt`): the drag is
/// taken past the touch slop when it goes down and no more than 0.7× as far sideways.
enum ImageViewerDismiss {
    static let slope: CGFloat = 0.7
    static let distance: CGFloat = 120
    static let velocity: CGFloat = 1000

    static func claims(dx: CGFloat, dy: CGFloat) -> Bool {
        dy > 0 && abs(dx) <= slope * dy
    }

    /// 1 → 0.8 over a screen's height.
    static func scale(dy: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 1 }
        return 1 - 0.2 * min(max(dy, 0) / height, 1)
    }

    /// Background and chrome: clear at half a screen.
    static func fade(dy: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 1 }
        return 1 - min(max(dy, 0) / (height / 2), 1)
    }

    static func closes(dy: CGFloat, velocityY: CGFloat) -> Bool {
        dy > distance || velocityY > velocity
    }

    /// The rect a `size` image takes fitted into `bounds`, centered.
    static func fitted(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fit = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fit.width / 2, y: bounds.midY - fit.height / 2, width: fit.width, height: fit.height)
    }
}

/// "Today 02:46" under the sender's name (Today / Yesterday / `MMM d`, then the time).
@MainActor
enum ImageViewerFormat {
    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = L10n.t("activity_list_day_today", "Today")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = L10n.t("activity_list_day_yesterday", "Yesterday")
        } else {
            day = monthDay.string(from: date)
        }
        return L10n.f("ios_image_viewer_time", "%1$@ %2$@", day, RaftFormat.clock(date))
    }
}

/// Where the image rests (31, Colo 5653): at 1× it is aspect-fitted and centred in the region
/// the controls leave free, so it never sits under Close, Share, the page counter or the info
/// capsule. Pinching in may take it under them. All rects are in the viewer's own (full-screen)
/// space; the result is physical insets from its edges.
enum ImageViewerFit {
    /// Between the region's bottom and the info capsule's top.
    static let capsuleGap: CGFloat = 12
    /// Between the page counter's bottom and the region's top.
    static let counterGap: CGFloat = 12

    struct Layout: Equatable {
        var size: CGSize
        /// The window's safe area (Duo folded: the system's status column on the trailing edge).
        var windowSafe: UIEdgeInsets = .zero
        /// The page's safe area under a horizontal navigation bar (top includes the bar).
        var pageSafe: UIEdgeInsets = .zero
        /// The system stacks the bars in a vertical column (Duo folded, unfolded landscape): Close
        /// and Share are in its column, which is the window's side safe area.
        var verticalBar = false
        var capsule: CGRect?
        var counter: CGRect?
    }

    static func insets(_ layout: Layout) -> UIEdgeInsets {
        let width = layout.size.width
        let height = layout.size.height
        let window = layout.windowSafe
        var insets = UIEdgeInsets(
            top: window.top,
            left: max(window.left, layout.pageSafe.left),
            bottom: window.bottom,
            right: max(window.right, layout.pageSafe.right)
        )
        if !layout.verticalBar {
            // The navigation bar (Close, Share) is in the page's top safe area.
            insets.top = max(insets.top, layout.pageSafe.top)
        }
        if let counter = layout.counter, counter.height > 0 {
            insets.top = max(insets.top, counter.maxY + counterGap)
        }
        if let capsule = layout.capsule, capsule.height > 0 {
            insets.bottom = max(insets.bottom, height - (capsule.minY - capsuleGap))
        }
        // Never less than a sliver of region.
        insets.top = min(max(insets.top, 0), max(height - insets.bottom - 1, 0))
        insets.left = min(max(insets.left, 0), max(width - insets.right - 1, 0))
        return insets
    }

    /// The scroll view's content insets that centre `content` in `bounds` inset by `fit`; content
    /// larger than that region (zoomed in) can be scrolled until its edges reach the region's.
    static func centering(content: CGSize, bounds: CGSize, fit: UIEdgeInsets) -> UIEdgeInsets {
        func axis(_ content: CGFloat, _ length: CGFloat, _ lead: CGFloat, _ trail: CGFloat) -> (CGFloat, CGFloat) {
            let region = length - lead - trail
            guard content < region else { return (lead, trail) }
            let start = lead + (region - content) / 2
            return (start, length - start - content)
        }
        let h = axis(content.width, bounds.width, fit.left, fit.right)
        let v = axis(content.height, bounds.height, fit.top, fit.bottom)
        return UIEdgeInsets(top: v.0, left: h.0, bottom: v.1, right: h.1)
    }
}
