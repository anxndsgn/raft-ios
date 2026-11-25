import SafariServices
import SwiftUI
import UIKit

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
        modifier(RaftNavigationTitle(title: title, hashPrefix: hashPrefix, subtitle: subtitle, glass: glass, topInset: .constant(0), trailing: { EmptyView() }))
    }

    /// The glass title with a trailing button (thread: Follow). With horizontal bars the button
    /// floats beside the capsule (`floatingGlassHeader`, which sets `topInset` for the page's
    /// scroll view); with the vertical bar the page keeps it in its own `.toolbar`.
    func raftNavigationTitle<Trailing: View>(_ title: String, subtitle: String? = nil, topInset: Binding<CGFloat>, @ViewBuilder glassTrailing: @escaping () -> Trailing) -> some View {
        modifier(RaftNavigationTitle(title: title, hashPrefix: false, subtitle: subtitle, glass: true, topInset: topInset, trailing: glassTrailing))
    }
}

private struct RaftNavigationTitle<Trailing: View>: ViewModifier {
    let title: String
    let hashPrefix: Bool
    let subtitle: String?
    let glass: Bool
    @Binding var topInset: CGFloat
    let trailing: () -> Trailing
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
                .topTitleOverlay(vertical) { navTitle }
                // The glass title: content runs to the top under it with the vertical bar (no
                // scroll edge); with horizontal bars it floats over the content (Colo 5725) and
                // the soft edge fades content under the status bar.
                .scrollEdgeEffectHidden(glass && vertical, for: .top)
                .floatingGlassHeader(glass && !vertical, topInset: $topInset, title: { navTitle }, trailing: trailing, accessory: { EmptyView() })
        }
    }
}

extension View {
    /// Colo 5725: with horizontal bars (iPhone, Duo unfolded portrait) a page whose content runs
    /// under its glass title hides the navigation bar and floats the back button, the capsule
    /// and `trailing` over the content instead. The top safe area is then the status bar's only,
    /// so the system's soft scroll edge fades content under the time and stops there, not at
    /// the capsule's bottom (no grey band under the capsule). The content starts 8 below the
    /// capsule: apply `topInset` as the page's scroll view's `.contentMargins(.top, …,
    /// for: .scrollContent)`, on the scroll view itself (here it would reach every scroll view in
    /// the page, the composer's attachment strip too). `accessory` (the offline banner) sits
    /// under the row.
    /// With the vertical bar (`enabled` false) nothing changes: the system bar keeps back and
    /// the page's items, the title is a `TopTitleBlock`.
    func floatingGlassHeader<Title: View, Trailing: View, Accessory: View>(
        _ enabled: Bool,
        topInset: Binding<CGFloat>,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) -> some View {
        modifier(FloatingGlassHeader(enabled: enabled, topInset: topInset, title: title, trailing: trailing, accessory: accessory))
    }
}

private struct FloatingGlassHeader<Title: View, Trailing: View, Accessory: View>: ViewModifier {
    let enabled: Bool
    @Binding var topInset: CGFloat
    let title: () -> Title
    let trailing: () -> Trailing
    let accessory: () -> Accessory
    @Environment(\.dismiss) private var dismiss
    /// The row's height below the safe-area top: the capsule's bottom (and the accessory's).
    @State private var height: CGFloat = 0

    /// 44pt buttons centred in the 54pt row a navigation bar would have.
    static var rowTop: CGFloat { 5 }

    func body(content: Content) -> some View {
        // Never branch on `enabled` around `content`: a fold would rebuild the page.
        content
            .toolbar(enabled ? .hidden : .automatic, for: .navigationBar)
            .onChange(of: enabled ? height + 8 : 0, initial: true) { _, inset in topInset = inset }
            .overlay(alignment: .top) {
                if enabled { header }
            }
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                title()
                    .padding(.horizontal, TopTitleBlock<EmptyView>.sideReserve)
                HStack(spacing: 0) {
                    backButton
                    Spacer(minLength: 0)
                    trailing()
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, Self.rowTop)
            accessory()
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .background {
            SwipeBackWithoutBar()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            NavigationBarFade()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(1)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.raftTextPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(HeaderTitleButtonStyle())
        .background(.ultraThinMaterial, in: Circle())
        .raftGlass(Circle(), interactive: true)
        .accessibilityLabel(Text(L10n.t("ios_back", "Back")))
        .raftLargeContent(systemImage: "chevron.left", label: L10n.t("ios_back", "Back"))
        .accessibilityIdentifier("header-back")
    }
}
/// The navigation bar's opacity around a page that hides it (`floatingGlassHeader`). SwiftUI
/// draws the bar in its own view (beside UIKit's hidden `UINavigationBar`, inside the navigation
/// controller's view) and moves the bar's content with the transition at full opacity: pushed
/// over Home, Search and the bell slid across over the incoming page's back button for 0.3–0.5s;
/// on a swipe back, Home's title stood at full opacity over the capsule while the page slid out.
/// - The page coming on screen (a push, or a pop back to it): the bar is gone from the first
///   frame (a swipe back to it: fades with the finger) and stays transparent while the page is
///   on top.
/// - The page going (a pop, or a push of a page that shows the bar): the bar fades in with the
///   transition, following the finger on a swipe; a cancelled swipe takes it back to 0.
/// The bar is opaque again once no such page is on top. Pages under the vertical bar (Duo
/// folded) keep the bar and never use this.
private struct NavigationBarFade: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        /// The pages of this kind on top, per navigation controller (a thread over a channel).
        private static var onTop: [ObjectIdentifier: Int] = [:]
        private weak var navigation: UINavigationController?
        private var isOnTop = false

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        private var nav: UINavigationController? { navigationController ?? parent?.navigationController }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let nav else { return }
            navigation = nav
            setOnTop(true, nav: nav)
            guard let coordinator = nav.transitionCoordinator else {
                Self.settle(nav)
                return
            }
            if coordinator.isInteractive {
                coordinator.animate(alongsideTransition: { _ in Self.setAlpha(0, nav) })
            } else {
                // A push (SwiftUI starts it without an animated appearance): gone from the
                // slide's first frame. The page's back button is on screen from that frame, and
                // the bar's items slide left into it: any fade (0.15s took 4 frames) still drew
                // Search and the bell over the back button. Masked as well: the bar's own hiding
                // animates its alpha back to 1 during the push.
                UIView.performWithoutAnimation {
                    Self.setAlpha(0, nav)
                    Self.setMasked(true, nav)
                }
            }
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.updateOnTop(nav)
                Self.settle(nav)
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let nav = navigation else { return }
            setOnTop(false, nav: nav)
            guard let coordinator = nav.transitionCoordinator else {
                Self.settle(nav)
                return
            }
            // The bar is hidden while the page is on top, and UIKit shows it again at full
            // opacity as the transition starts: start it from 0 (no animation), then fade it in.
            // Another page of this kind coming in keeps it transparent (its own
            // `viewWillAppear` runs next).
            coordinator.animate(alongsideTransition: { _ in
                guard !Self.hidesBar(nav) else { return }
                UIView.performWithoutAnimation {
                    Self.setAlpha(0, nav)
                    Self.setMasked(false, nav)
                }
                Self.setAlpha(1, nav)
            }) { [weak self] _ in
                self?.updateOnTop(nav)
                Self.settle(nav)
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard let nav = navigation else { return }
            setOnTop(false, nav: nav)
            if nav.transitionCoordinator == nil { Self.settle(nav) }
        }

        /// After a transition, finished or cancelled (a cancelled swipe back also calls the
        /// page's `viewWillAppear`, with the same cancelled transition): on top if its page is
        /// the navigation controller's top page.
        private func updateOnTop(_ nav: UINavigationController) {
            var controller: UIViewController? = self
            while let current = controller, current.parent !== nav { controller = current.parent }
            setOnTop(controller != nil && controller === nav.topViewController, nav: nav)
        }

        private func setOnTop(_ value: Bool, nav: UINavigationController) {
            guard value != isOnTop else { return }
            isOnTop = value
            let key = ObjectIdentifier(nav)
            let count = (Self.onTop[key] ?? 0) + (value ? 1 : -1)
            Self.onTop[key] = count > 0 ? count : nil
        }

        private static func hidesBar(_ nav: UINavigationController) -> Bool { (onTop[ObjectIdentifier(nav)] ?? 0) > 0 }

        /// The bars drawn over the pages: UIKit's and SwiftUI's own (`UIKitNavigationBar`), direct
        /// subviews of the navigation controller's view.
        private static func bars(_ nav: UINavigationController) -> [UIView] {
            var views: [UIView] = [nav.navigationBar]
            for view in nav.view.subviews where view !== nav.navigationBar && String(describing: type(of: view)).contains("NavigationBar") {
                views.append(view)
            }
            return views
        }

        private static func setAlpha(_ alpha: CGFloat, _ nav: UINavigationController) {
            for bar in bars(nav) where bar.alpha != alpha { bar.alpha = alpha }
        }

        /// An empty mask: the bar draws nothing whatever its alpha.
        private static func setMasked(_ masked: Bool, _ nav: UINavigationController) {
            for bar in bars(nav) {
                let isMasked = bar.layer.mask?.name == maskName
                if masked, !isMasked {
                    let mask = CALayer()
                    mask.name = maskName
                    bar.layer.mask = mask
                } else if !masked, isMasked {
                    bar.layer.mask = nil
                }
            }
        }

        private static let maskName = "raft.navigationBarFade"

        /// After a transition: transparent while such a page is on top, else opaque (unmasked).
        private static func settle(_ nav: UINavigationController) {
            let hides = hidesBar(nav)
            setAlpha(hides ? 0 : 1, nav)
            if !hides { setMasked(false, nav) }
        }
    }
}

/// The swipe back on a page that hides the navigation bar (`floatingGlassHeader`). UIKit's own
/// back swipes, from the edge and from the content, never start while the bar is hidden (they
/// don't even ask their delegate), so while such a page is on screen the navigation controller
/// gets one more pan, driving the same interactive pop as the system's: a rightward swipe from
/// anywhere on the page, whenever there is a page to go back to and no transition is running.
private struct SwipeBackWithoutBar: UIViewRepresentable {
    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {}

    @MainActor
    final class Marker: UIView {
        private weak var navigation: UINavigationController?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                guard navigation == nil, let nav = navigationController() else { return }
                navigation = nav
                SwipeBack.hold(nav)
            } else if let nav = navigation {
                navigation = nil
                SwipeBack.release(nav)
            }
        }

        private func navigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let nav = controller.navigationController {
                    return nav
                }
                responder = current.next
            }
            return nil
        }
    }
}

@MainActor
private final class SwipeBack: NSObject, UIGestureRecognizerDelegate {
    private static var installed: [ObjectIdentifier: SwipeBack] = [:]

    private weak var navigation: UINavigationController?
    private var pan: UIPanGestureRecognizer?
    private var holds = 0

    static func hold(_ nav: UINavigationController) {
        let key = ObjectIdentifier(nav)
        if let existing = installed[key] {
            existing.holds += 1
            return
        }
        // The system's back swipes send this action to their target, the interactive transition.
        let action = NSSelectorFromString("handleNavigationTransition:")
        guard let system = nav.interactivePopGestureRecognizer?.delegate as? NSObject,
              system.responds(to: action) else { return }
        let swipe = SwipeBack()
        swipe.navigation = nav
        swipe.holds = 1
        let pan = UIPanGestureRecognizer(target: system, action: action)
        pan.delegate = swipe
        pan.maximumNumberOfTouches = 1
        nav.view.addGestureRecognizer(pan)
        swipe.pan = pan
        installed[key] = swipe
    }

    static func release(_ nav: UINavigationController) {
        let key = ObjectIdentifier(nav)
        guard let swipe = installed[key] else { return }
        swipe.holds -= 1
        guard swipe.holds <= 0 else { return }
        if let pan = swipe.pan { pan.view?.removeGestureRecognizer(pan) }
        installed[key] = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigation, nav.viewControllers.count > 1, nav.transitionCoordinator == nil,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pan.view)
        return velocity.x > 0 && velocity.x > abs(velocity.y)
    }
}

/// A 44pt glass circle for a button floating in `floatingGlassHeader`, like the back button.
struct FloatingHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.raftTextPrimary)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .background(.ultraThinMaterial, in: Circle())
            .raftGlass(Circle(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
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

    /// Set by the page's `topTitleOverlay`: the title is drawn there, over the page, and this
    /// block only holds its place.
    @Environment(TopTitleSlot.self) private var slot: TopTitleSlot?

    var body: some View {
        placedTitle
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
            .background {
                NavigationBarPassThrough()
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    @ViewBuilder private var placedTitle: some View {
        if let slot {
            title()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slot.frame = $0 }
        } else {
            title()
        }
    }
}

/// Where `TopTitleBlock` holds the title's place, in the window.
@MainActor @Observable
final class TopTitleSlot {
    var frame: CGRect?
}

extension View {
    /// Draws a `TopTitleBlock`'s title over the page, where the block holds its place. The block
    /// sits in the page's top `.safeAreaBar` and moves up out of it into the navigation bar's
    /// empty row (Duo folded); the bar's view only takes touches within its own frame, so a
    /// tap on the channel's capsule there went to the message under it. Apply outside the
    /// `.safeAreaBar` that holds the block.
    func topTitleOverlay<Title: View>(_ shown: Bool, @ViewBuilder title: @escaping () -> Title) -> some View {
        modifier(TopTitleOverlay(shown: shown, title: title))
    }
}

private struct TopTitleOverlay<Title: View>: ViewModifier {
    let shown: Bool
    let title: () -> Title
    @State private var slot = TopTitleSlot()

    func body(content: Content) -> some View {
        content
            .environment(slot)
            .overlay(alignment: .topLeading) {
                if shown, let frame = slot.frame {
                    GeometryReader { proxy in
                        let origin = proxy.frame(in: .global).origin
                        title()
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
                    }
                    .ignoresSafeArea()
                    .accessibilitySortPriority(1)
                }
            }
    }
}

/// With the vertical bar the navigation bar's buttons are drawn in the trailing column, but the
/// `UINavigationBar` itself stays as an empty 58pt band across the top of the page (Duo folded:
/// y 24–82) and took every touch there: the title block sits in that band, and a tap on the
/// channel's capsule never reached it. While a page shows a `TopTitleBlock` the band lets
/// touches through to the page. Counted per bar: the page pushed over another one with a block
/// comes before the other's goes. The navigation controller turns the bar's interaction off for
/// each transition and back on at its end, so it is set again once a transition has finished.
private struct NavigationBarPassThrough: UIViewRepresentable {
    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {}

    @MainActor
    final class Marker: UIView {
        private static var holds: [ObjectIdentifier: Int] = [:]
        private weak var navigation: UINavigationController?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                guard navigation == nil, let nav = navigationController() else { return }
                navigation = nav
                Self.holds[ObjectIdentifier(nav.navigationBar), default: 0] += 1
                Self.apply(nav)
            } else if let nav = navigation {
                navigation = nil
                let key = ObjectIdentifier(nav.navigationBar)
                let count = (Self.holds[key] ?? 1) - 1
                Self.holds[key] = count > 0 ? count : nil
                Self.apply(nav)
            }
        }

        /// The bar's interaction for its holds now, and again once a running transition ends.
        private static func apply(_ nav: UINavigationController) {
            let bar = nav.navigationBar
            let held = (holds[ObjectIdentifier(bar)] ?? 0) > 0
            if let coordinator = nav.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { _ in
                    DispatchQueue.main.async {
                        let held = (holds[ObjectIdentifier(bar)] ?? 0) > 0
                        if held { bar.isUserInteractionEnabled = false }
                    }
                }
                // UIKit restores the bar's interaction itself at the end of the transition.
                if held { bar.isUserInteractionEnabled = false }
            } else {
                bar.isUserInteractionEnabled = !held
            }
        }

        private func navigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let nav = controller.navigationController {
                    return nav
                }
                responder = current.next
            }
            return nil
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
