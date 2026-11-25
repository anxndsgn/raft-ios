import SafariServices
import SwiftUI

/// `SFSafariViewController` in a sheet (terms, password reset, web settings).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Color.raftInk)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension View {
    /// Presents `url` in Safari when set.
    func safariSheet(_ url: Binding<URL?>) -> some View {
        sheet(item: url) { value in
            SafariView(url: value).ignoresSafeArea()
        }
    }

    /// The inline title of a pushed or root screen (§2.12): custom principal item plus a plain
    /// title for VoiceOver and the back menu. With the vertical bar (Duo folded, unfolded
    /// landscape) the title is a block at the top of the content instead (`TopTitleBlock`), so
    /// content scrolls under it and fades rather than running through the title.
    /// `glass`: a page whose content scrolls under the title (thread) shows it in the glass
    /// capsule (`GlassTitle`, XIN 5662 / Colo 5665) and its content has no top scroll edge.
    func raftNavigationTitle(_ title: String, hashPrefix: Bool = false, subtitle: String? = nil, glass: Bool = false) -> some View {
        modifier(RaftNavigationTitle(title: title, hashPrefix: hashPrefix, subtitle: subtitle, glass: glass))
    }
}

private struct RaftNavigationTitle: ViewModifier {
    let title: String
    let hashPrefix: Bool
    let subtitle: String?
    let glass: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder private var navTitle: some View {
        if glass {
            GlassTitle(title: title, hashPrefix: hashPrefix, subtitle: subtitle, typeSize: typeSize)
        } else {
            NavTitle(title: title, hashPrefix: hashPrefix, subtitle: subtitle, typeSize: typeSize)
        }
    }

    func body(content: Content) -> some View {
        VerticalBarReader { vertical in
            content
                .navigationTitle(Text(verbatim: title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        if vertical {
                            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                        } else {
                            navTitle
                        }
                    }
                }
                .safeAreaBar(edge: .top, spacing: 0) {
                    if vertical {
                        TopTitleBlock { navTitle }
                    }
                }
        }
    }
}

extension View {
    /// 大字号补充 B.3: a 44pt toolbar button keeps its size at accessibility sizes; a long
    /// press shows its symbol and name in the system's large content viewer instead.
    func raftLargeContent(systemImage: String, label: String) -> some View {
        accessibilityShowsLargeContentViewer {
            Image(systemName: systemImage)
            Text(verbatim: label)
        }
    }
}

/// True where the system stacks the bars vertically (`toolbarVerticalEdge`, iOS 27.1); false
/// before 27.1 and wherever the bars are horizontal.
struct VerticalBarReader<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            VerticalBarReader271(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarReader271<Content: View>: View {
    let content: (Bool) -> Content
    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View { content(edge != nil) }
}

/// The page title in a Liquid Glass capsule, the back button's glass (XIN 5662, Colo 5665 /
/// 5677): "# all" 15 SemiBold over the subtitle 12 Regular, no line spacing, each line at most
/// 220 wide and truncated; 14 × 5 padding (44 tall with a subtitle at the standard size, as
/// the back button). The capsule hugs the text and follows Dynamic Type up to xLarge. Content
/// scrolls to the screen's top under it: no top scroll edge, blur or mask.
struct GlassTitle: View {
    let title: String
    var hashPrefix = false
    var subtitle: String?
    /// The page's text size: the bar hosts its items at its own (see `NavTitle`).
    var typeSize: DynamicTypeSize?

    static let lineWidth: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            CappedWidth(max: Self.lineWidth) {
                ((hashPrefix ? Text(verbatim: "# ").foregroundStyle(Color.raftTextTertiary) : Text(verbatim: ""))
                    + Text(verbatim: title).foregroundStyle(Color.raftTextPrimary))
                    .raftStyle(.grotesk(RaftFont.semibold, 15, relativeTo: .subheadline))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let subtitle, !subtitle.isEmpty {
                CappedWidth(max: Self.lineWidth) {
                    Text(verbatim: subtitle)
                        .raftStyle(.grotesk(RaftFont.regular, 12, relativeTo: .caption))
                        .foregroundStyle(Color.raftTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: 36)
        // The glass alone left text behind it readable (Colo 5672); the thin material under it
        // blurs that to light and dark only, as under the back button.
        .background(.ultraThinMaterial, in: Capsule())
        .raftGlass(Capsule())
        .contentShape(Capsule())
        .dynamicTypeSize(...min(typeSize ?? .xLarge, .xLarge))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityShowsLargeContentViewer {
            Text(verbatim: (hashPrefix ? "# " : "") + title)
        }
    }
}

/// The glass title as a button: the capsule shrinks to 0.97 while pressed.
struct HeaderTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

/// A page title shown at the top of the content where the bars are vertical (大字号补充 A.4),
/// at least 8 below the safe-area top. It sits in the page's `.safeAreaBar(edge: .top)` with no
/// background of its own: the system's soft scroll edge fades content scrolled under it, or (the
/// glass title) the capsule carries its own glass. Its height is the title's real height
/// (Dynamic Type), so the content's top inset follows it.
struct TopTitleBlock<Title: View>: View {
    @ViewBuilder var title: () -> Title
    /// Kept clear on both sides of the screen, whatever the side safe areas (Colo 5682): the
    /// back button's 44 + 16 + 8. The title is centred on the screen, not on the content
    /// column beside the Duo's vertical bar.
    static var sideReserve: CGFloat { 68 }
    @State private var insets = BarInsets()
    @State private var height: CGFloat = 0

    /// With the vertical bar the page's top safe area still holds the navigation bar's top row
    /// (82 on the Duo folded, which no bar can give back). The block moves up into that row so its
    /// bottom, the subtitle's, is where the content starts: no blank band under the title, and
    /// the soft edge ends at the subtitle. Never higher than the window's safe-area top (taller
    /// titles at large Dynamic Type push the content down instead). Measured before this
    /// padding: no feedback.
    private var lift: CGFloat { min(max(insets.windowTop - insets.originY, -height), 0) }

    var body: some View {
        title()
            .padding(.horizontal, Self.sideReserve)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(.container, edges: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .padding(.top, lift)
            .background(alignment: .top) {
                BarInsetsReader { insets = $0 }
                    .frame(height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// The "Copied" pill (§3-12).
struct ToastPill: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .raftFont(.grotesk(RaftFont.semibold, 14, relativeTo: .subheadline))
            .foregroundStyle(Color.raftTextPrimary)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .raftGlass(Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

/// A text link: SemiBold 15, optional underline, padded to a 44pt target.
struct LinkButton: View {
    let title: String
    var underline = true
    var weak = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(weak ? .custom(RaftFont.medium, size: 14, relativeTo: .subheadline) : RaftFont.link.font)
                .underline(underline, color: Color.raftTextPrimary)
                .baselineOffset(0)
                .foregroundStyle(weak ? Color.raftTextSecondary : Color.raftTextPrimary)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The centered destructive text button (Sign out).
struct DangerTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .raftFont(.grotesk(RaftFont.semibold, 16, relativeTo: .body))
                .foregroundStyle(Color.raftDanger)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum Masking {
    /// `m***@raft.build`.
    static func email(_ value: String?) -> String? {
        guard let value, let at = value.firstIndex(of: "@"), at > value.startIndex else { return value }
        if value[value.index(after: value.startIndex)..<at].allSatisfy({ $0 == "*" }) { return value }
        return String(value[value.startIndex]) + "***" + value[at...]
    }
}

extension Text {
    /// `format` (one `%1$@`) with the argument in a stronger style.
    static func emphasized(_ format: String, _ argument: String, base: RaftFont, strongFont: String, strongColor: Color) -> Text {
        let parts = format.components(separatedBy: "%1$@")
        guard parts.count == 2 else { return Text(verbatim: String(format: format, argument)) }
        return Text(verbatim: parts[0]).raftStyle(base)
            + Text(verbatim: argument).font(.custom(strongFont, size: base.size, relativeTo: base.relativeTo)).foregroundStyle(strongColor)
            + Text(verbatim: parts[1]).raftStyle(base)
    }
}
