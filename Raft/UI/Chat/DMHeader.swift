import SwiftUI

// MARK: 33a / 33b DM header: big avatar + name capsule

/// The top of a DM's content (33a): the peer's 56pt avatar with a glass name capsule pressed
/// into its bottom edge, and the "Claude Code · Online" line under it. Back and ⓘ stay in the
/// system navigation bar (which on Duo folded / unfolded landscape turns into the trailing
/// vertical bar); this block is shown in `.safeAreaBar(edge: .top)` under that bar, so messages
/// scroll under it.
///
/// Layout, from the block's top: avatar 0–56; capsule 46–72 (its centre 3 below the avatar's
/// bottom edge, so it covers the avatar's last 10pt); caption 76–92.
///
/// With a horizontal navigation bar (iPhone, Duo unfolded portrait) the block moves up into the
/// bar's row, avatar top at the safe-area top, only as wide as the capsule, so the system's back
/// and ⓘ stay clear. With the vertical bar (Duo folded and unfolded landscape: no top inset) it is
/// at least 8 below the screen's top (`minimumTop`). The short one-line version for low windows
/// (矮版) is not built yet: low windows get this one too. Left and right it is
/// centred in the corner-adapted safe area (`BarInsetsReader`), so neither the side safe area (the
/// Duo's status column with the vertical bar) nor a rounded display corner reaches it. Under the
/// caption the block is 32 deeper, with the canvas fading out over it, so the fade reaches 32
/// below the caption; the message list's top inset follows the block's real height.
struct DMHeaderBar: View {
    let peer: Persona
    /// "Ruby", or "XIN (you)" for a DM with yourself.
    let name: String
    /// "Claude Code · Online" (agents), "Online" / "Away" (people); same string as the old title.
    let subtitle: String?
    /// The DM info page (the same as the toolbar's ⓘ). `nil` while there is no such page (§10-2:
    /// entries without a target are hidden): then the avatar and capsule are not a button.
    var info: (() -> Void)?

    static let height: CGFloat = 92
    /// The fade under the caption.
    static let fadeExtension: CGFloat = 32
    /// The least space between the window's safe-area top and the bar.
    static let minimumTop: CGFloat = 8

    @State private var insets = BarInsets()

    /// Moves the block to where the avatar's top belongs, from where SwiftUI put it. Under a
    /// horizontal navigation bar it goes up into the bar's row (avatar top = the window's
    /// safe-area top, between the system's back and ⓘ); with the vertical bar (no top inset) it
    /// goes down to `minimumTop`. The origin is measured before this padding, so it never feeds back.
    private var top: CGFloat {
        let wanted = insets.windowTop < Self.minimumTop ? Self.minimumTop : insets.windowTop
        return wanted - insets.originY
    }

    var body: some View {
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
            // Centred in the safe area.
            .padding(.leading, 16 + insets.leading)
            .padding(.trailing, 16 + insets.trailing)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .top)
        .padding(.top, top)
        .background(alignment: .top) {
            // The block's origin and its avatar band, full width: where the insets are measured.
            BarInsetsReader { insets = $0 }
                .frame(height: max(56 + top, 1))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.bottom, Self.fadeExtension)
        // The fade (大字号补充 A.4): canvas behind the header, then canvas → clear over the 32
        // under it, so messages scrolled up are gone before they reach the caption.
        .background {
            VStack(spacing: 0) {
                Color.raftCanvas
                LinearGradient(colors: [.raftCanvas, .raftCanvas.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fadeExtension)
            }
            .ignoresSafeArea(.container, edges: .top)
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
    /// The bar's top in the window (before its own top padding).
    var originY: CGFloat = 20
}

private struct BarInsetsReader: UIViewRepresentable {
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
                originY: inWindow.minY.rounded()
            )
            guard value != last else { return }
            last = value
            report?(value)
        }
    }
}
