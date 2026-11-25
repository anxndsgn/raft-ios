import SwiftUI

// MARK: 33a / 33b DM header: big avatar + name capsule

/// The top of a DM's content (33a): the peer's 44pt avatar with a glass name capsule pressed
/// into its bottom edge, and the "Claude Code" line under it. Back and ⓘ stay in the
/// system navigation bar (which on Duo folded / unfolded landscape turns into the trailing
/// vertical bar); this block is shown in `.safeAreaBar(edge: .top)` under that bar, so messages
/// scroll under it.
///
/// Layout, from the block's top: avatar 6–50 (its centre at 28, level with the centres of the
/// bar's round buttons); capsule 40–66 (its centre 3 below the avatar's bottom edge, so it
/// covers the avatar's last 10pt); caption 70–86.
///
/// With a horizontal navigation bar (iPhone, Duo unfolded portrait) the block moves up into the
/// bar's row, its top at the safe-area top (avatar centre at safe-area top + 28, level with back
/// and ⓘ), only as wide as the capsule, so the system's back and ⓘ stay clear. With the vertical bar (Duo folded and unfolded landscape: no top inset) it is
/// at least 8 below the screen's top (`minimumTop`). The short one-line version for low windows
/// (矮版) is not built yet: low windows get this one too. Left and right it is
/// centred in the corner-adapted safe area (`BarInsetsReader`), so neither the side safe area (the
/// Duo's status column with the vertical bar) nor a rounded display corner reaches it. The block
/// has no background or fade of its own (XIN 5497): only the system's soft scroll edge
/// (`.scrollEdgeEffectStyle(.soft, for: .top)` on the message list) fades messages under it,
/// and it ends at the caption's bottom, the block's bottom; the list's top inset follows the
/// block's real height.
struct DMHeaderBar: View {
    let peer: Persona
    /// "Ruby", or "XIN (you)" for a DM with yourself.
    let name: String
    /// "Claude Code" (agents: the runtime only, presence is the dot by the name), "Online" /
    /// "Away" (people).
    let subtitle: String?
    /// The DM info page (the same as the toolbar's ⓘ). `nil` while there is no such page (§10-2:
    /// entries without a target are hidden): then the avatar and capsule are not a button.
    var info: (() -> Void)?

    static let height: CGFloat = 86
    /// The avatar's top in the block: its centre 28 below the block's top, as the bar buttons'.
    static let avatarTop: CGFloat = 6
    /// The least space between the window's safe-area top and the bar.
    static let minimumTop: CGFloat = 8

    @State private var insets = BarInsets()
    /// The block's origin in the window (before its top padding), from SwiftUI's layout. The
    /// reader's UIView is not laid out again when only its position changes, so its `originY`
    /// went stale when the bar's top inset changed in a scroll (Duo folded: 82 → 24) and the
    /// block was pushed up off the screen.
    @State private var origin: CGFloat?

    /// Moves the block to where the avatar's top belongs, from where SwiftUI put it. Under a
    /// horizontal navigation bar it goes up into the bar's row (avatar top = the bar's top, the
    /// status bar's bottom, between the system's back and ⓘ); with the vertical bar (no top inset) it
    /// goes down to `minimumTop`. The origin is measured before this padding, so it never feeds back.
    private func top(verticalBar: Bool) -> CGFloat {
        let wanted: CGFloat
        if !verticalBar, let barTop = insets.navigationBarTop {
            // Horizontal bar: the block's top in the bar's row, the avatar level with back and ⓘ.
            wanted = barTop
        } else {
            wanted = insets.windowTop < Self.minimumTop ? Self.minimumTop : insets.windowTop
        }
        return wanted - (origin ?? insets.originY)
    }

    var body: some View {
        VerticalBarReader { vertical in block(top: top(verticalBar: vertical)) }
    }

    private func block(top: CGFloat) -> some View {
        Group {
            VStack(spacing: 4) {
                identity
                if let subtitle {
                    Text(verbatim: subtitle)
                        .raftFont(.caption)
                        .foregroundStyle(Color.raftTextTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            // Capsule and caption grow with Dynamic Type up to XXXL (大字号补充 A.5).
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.top, Self.avatarTop)
            // Centred in the safe area.
            .padding(.leading, 16 + insets.leading)
            .padding(.trailing, 16 + insets.trailing)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .top)
        .padding(.top, top)
        // The padding grows the block from its origin, so this never feeds back.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY.rounded() } action: { origin = $0 }
        .background(alignment: .top) {
            // The block's origin and its avatar band, full width: where the insets are measured.
            BarInsetsReader { insets = $0 }
                .frame(height: max(Self.avatarTop + 44 + top, 1))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    // MARK: Avatar + capsule

    @ViewBuilder private var identity: some View {
        if let info {
            Button(action: info) { avatarAndCapsule(interactive: true) }
                .buttonStyle(PressDimButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilityName))
                .accessibilityHint(Text(L10n.t("ios_dm_header_hint", "Shows conversation details")))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("dm-header")
        } else {
            avatarAndCapsule(interactive: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilityName))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("dm-header")
        }
    }

    /// "Ruby, online".
    private var accessibilityName: String {
        [name, peer.presence?.label].compactMap { $0 }.joined(separator: ", ")
    }

    private func avatarAndCapsule(interactive: Bool) -> some View {
        ZStack(alignment: .bottom) {
            AvatarView(persona: peer, size: .header)
                .padding(.bottom, 16)
            capsule(interactive: interactive)
        }
        .contentShape(Rectangle())
    }

    private func capsule(interactive: Bool) -> some View {
        HStack(spacing: 6) {
            if let presence = peer.presence {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(presence.color)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.raftInk, lineWidth: 1))
                    .frame(width: 8, height: 8)
            }
            CappedWidth(max: 180) {
                Text(verbatim: name)
                    .raftFont(.segment)
                    .foregroundStyle(Color.raftTextPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .raftGlass(Capsule(), interactive: interactive)
        .overlay(Capsule().stroke(Color.raftInk.opacity(0.08), lineWidth: 0.5).padding(-0.25))
    }

}

/// The header's avatar + capsule: 0.6 opacity while pressed (33a).
private struct PressDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Its child at most `max` wide, else its own width (`.frame(maxWidth:)` would grow a short name
/// to the full width).
private struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(capped(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: Swift.min(proposal.width ?? max, max), height: proposal.height)
    }
}

// MARK: Corner-adapted insets

/// The insets the bar's circles keep: the window's safe area left and right, or more where a
/// rounded display corner reaches into the band (`safeArea(cornerAdaptation: .horizontal)`);
/// and the window's top inset.
struct BarInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    var windowTop: CGFloat = 20
    /// The top of the horizontal navigation bar in the window (the status bar's bottom), when
    /// there is one. The window's safe-area top already includes the bar itself.
    var navigationBarTop: CGFloat?
    /// The bar's top in the window (before its own top padding).
    var originY: CGFloat = 20
}

struct BarInsetsReader: UIViewRepresentable {
    let report: (BarInsets) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.report = report
        view.setNeedsLayout()
    }

    final class ReaderView: UIView {
        var report: ((BarInsets) -> Void)?
        private var last: BarInsets?
        private lazy var guide = layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
            // The guide settles in the same pass; read it again once it has.
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        /// The navigation bar's top in the window, if this view is under a shown navigation bar.
        private func navigationBarTop(in window: UIWindow) -> CGFloat? {
            var responder: UIResponder? = self
            while let r = responder {
                if let vc = r as? UIViewController, let nav = vc.navigationController {
                    let bar = nav.navigationBar
                    guard !nav.isNavigationBarHidden, !bar.isHidden, bar.bounds.height > 0 else { return nil }
                    return bar.convert(bar.bounds, to: window).minY.rounded()
                }
                responder = r.next
            }
            return nil
        }

        private func measure() {
            guard let window, bounds.width > 0 else { return }
            // SwiftUI gives a hosted UIView no safe area of its own, so the guide here only
            // carries the corner adaptation; the window's safe area (Duo folded: the status
            // column on the right) is added from the window, for the part this view overlaps.
            let frame = guide.layoutFrame
            let inWindow = convert(bounds, to: window)
            let safe = window.safeAreaInsets
            let left = max(frame.minX - bounds.minX, safe.left - inWindow.minX, 0)
            let right = max(bounds.maxX - frame.maxX, safe.right - (window.bounds.maxX - inWindow.maxX), 0)
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let value = BarInsets(
                leading: (rtl ? right : left).rounded(),
                trailing: (rtl ? left : right).rounded(),
                windowTop: window.safeAreaInsets.top,
                navigationBarTop: navigationBarTop(in: window),
                originY: inWindow.minY.rounded()
            )
            guard value != last else { return }
            last = value
            report?(value)
        }
    }
}
