import SwiftUI
import UIKit
import os

private let tabBarLog = Logger(subsystem: "com.xinan.raft", category: "tabbar")

extension View {
    /// Pages with a composer (conversation, thread) have no tab bar. The bar behaves as part
    /// of the page underneath: it never moves, fades or scales; the chat page slides in over it
    /// on push and slides away to reveal it on pop (back button or interactive swipe, also when
    /// the swipe is cancelled halfway).
    ///
    /// Why not `.toolbar(.hidden, for: .tabBar)`: SwiftUI applies that preference once the
    /// navigation transition has settled, so on a pop the bar appears from nothing after the
    /// page is already in place. And `hidesBottomBarWhenPushed` itself does nothing here:
    /// SwiftUI's `NavigationStack` is not the tab's own controller (it sits inside a
    /// `TabHostingController`), and UIKit only honours the flag for a navigation controller
    /// that is the direct child of the `UITabBarController`.
    func hidesTabBarWhenPushed() -> some View {
        background {
            HidesTabBarWhenPushed()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct HidesTabBarWhenPushed: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Marker { Marker() }
    func updateUIViewController(_ controller: Marker, context: Context) {}

    /// Lives inside the page; tags the page's controller in the stack and reports its
    /// appearance transitions to `TabBarSlide`.
    final class Marker: UIViewController {
        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            tagPage(from: parent)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            tagPage(from: parent)
            TabBarSlide.pageTransition(for: self)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            TabBarSlide.pageTransition(for: self)
        }

        /// The ancestor that is (or is about to be) pushed: SwiftUI's hosting controller.
        /// Tagged as early as possible so the transition that shows it already knows.
        private func tagPage(from start: UIViewController?) {
            var controller = start
            while let current = controller {
                if current.parent == nil || current.parent is UINavigationController {
                    TabBarSlide.tag(current)
                    return
                }
                controller = current.parent
            }
        }
    }
}

/// Keeps the tab bar still under the chat page during navigation transitions.
///
/// The state is the public `UITabBarController.setTabBarHidden`: hidden while a tagged page is
/// on top, which also gives that page the bottom safe area without the bar. During a
/// transition between a tagged page and one with the bar, the bar stays exactly where it is
/// on screen, as if it were part of the page underneath, and the chat page covers it:
/// - A bar along the bottom (drawn inside `UITabBar`) is put between the two pages for the
///   transition, so the chat page slides over it and away from it.
/// - The floating bar (iPhone Duo folded: a column on the trailing edge, drawn outside
///   `UITabBar`) is hidden at once on push with a snapshot of it between the pages; on pop it
///   is masked frame by frame where the chat page still covers it.
/// While the bar is shown the tagged page's safe area is held at its bar-less value, so its
/// composer never moves. At the end the state is set from whatever is on top (a cancelled
/// swipe leaves the chat on top: hidden again, under the chat page).
@MainActor
enum TabBarSlide {
    private static let tagged = NSHashTable<UIViewController>.weakObjects()
    private static var active: [ObjectIdentifier: Driver] = [:]

    static func tag(_ controller: UIViewController) {
        tagged.add(controller)
    }

    static func isTagged(_ controller: UIViewController?) -> Bool {
        guard let controller else { return false }
        return tagged.contains(controller)
    }

    static func pageTransition(for marker: UIViewController) {
        guard let nav = marker.navigationController, let tbc = nav.tabBarController else { return }
        guard let coordinator = nav.transitionCoordinator,
              let from = coordinator.viewController(forKey: .from),
              let to = coordinator.viewController(forKey: .to),
              from.navigationController === nav || to.navigationController === nav || nav.viewControllers.contains(to)
        else {
            // Not a push or pop (tab switch, first appearance, scene): settle after this pass,
            // when the selected tab's stack is final.
            DispatchQueue.main.async { sync(tbc) }
            return
        }
        let key = ObjectIdentifier(nav)
        if let driver = active[key], driver.coordinator === coordinator { return }
        let hideFrom = isTagged(from)
        let hideTo = isTagged(to)
        guard hideFrom != hideTo else {
            coordinator.animate(alongsideTransition: nil) { _ in sync(tbc) }
            if hideTo { tbc.setTabBarHidden(true, animated: false) }
            return
        }
        let driver = Driver(nav: nav, tbc: tbc, coordinator: coordinator, from: from, to: to, hideAtEnd: hideTo)
        active[key] = driver
        driver.start()
        // Both pages are in place once the transition animates: the bar goes between them.
        coordinator.animate(alongsideTransition: { _ in
            UIView.performWithoutAnimation { driver.tick() }
        }) { context in
            driver.finish(cancelled: context.isCancelled)
            if active[key] === driver { active[key] = nil }
        }
    }

    /// The state for what is on top of the selected tab now.
    static func sync(_ tbc: UITabBarController) {
        guard active.isEmpty else { return }
        let hidden = isTagged(topOfSelectedStack(tbc))
        if tbc.isTabBarHidden != hidden {
            tabBarLog.debug("sync hidden=\(hidden)")
            if !hidden { BarVisual.restoreHidden() }
            tbc.setTabBarHidden(hidden, animated: false)
        }
    }

    private static func topOfSelectedStack(_ tbc: UITabBarController) -> UIViewController? {
        func navigation(in controller: UIViewController?) -> UINavigationController? {
            guard let controller else { return nil }
            if let nav = controller as? UINavigationController { return nav }
            for child in controller.children {
                if let nav = navigation(in: child) { return nav }
            }
            return nil
        }
        return navigation(in: tbc.selectedViewController)?.topViewController
    }

    /// One push or pop between a tagged page and a page with the bar.
    @MainActor final class Driver {
        private enum Ride {
            /// The tab bar itself is inside the bar page.
            case underlay(Underlay)
            /// The bar is masked frame by frame where the chat page covers it.
            case tracked
        }

        let nav: UINavigationController
        let tbc: UITabBarController
        let coordinator: UIViewControllerTransitionCoordinator
        let isPush: Bool
        /// The page that has the bar.
        let barPage: UIViewController
        /// The page drawn above the other one (the incoming one on push, the leaving one on pop).
        let topPage: UIViewController
        /// The page without the bar, whose safe area is held while the bar is out.
        let chatPage: UIViewController
        let hideAtEnd: Bool
        private var ride: Ride = .tracked
        private var savedChatInsets: UIEdgeInsets = .zero
        private var link: CADisplayLink?
        private var tracked: [UIView] = []
        private var finished = false

        init(nav: UINavigationController, tbc: UITabBarController, coordinator: UIViewControllerTransitionCoordinator,
             from: UIViewController, to: UIViewController, hideAtEnd: Bool) {
            self.nav = nav
            self.tbc = tbc
            self.coordinator = coordinator
            // A push keeps the leaving page in the stack; a pop has already removed it.
            isPush = nav.viewControllers.contains(from)
            barPage = hideAtEnd ? from : to
            chatPage = hideAtEnd ? to : from
            topPage = isPush ? to : from
            self.hideAtEnd = hideAtEnd
        }

        func start() {
            savedChatInsets = chatPage.additionalSafeAreaInsets
            BarVisual.restoreHidden()
            if tbc.isTabBarHidden { tbc.setTabBarHidden(false, animated: false) }
            layOut()
            let views = BarVisual.views(in: tbc)
            // The bar as it looks at rest on its page: taken now when it is on screen (push),
            // else the one taken when this page was left (pop: the bar is not drawn yet).
            let picture = hideAtEnd ? BarPicture(of: views) : BarPicture.stored(for: barPage, matching: views)
            if let picture, let underlay = Underlay(picture: picture, chat: chatPage, bar: barPage) {
                if hideAtEnd { BarPicture.store(picture, for: barPage) }
                ride = .underlay(underlay)
                // The real bar stays laid out (the pages' safe areas keep it) but out of sight.
                for view in views { BarVisual.hideUntilShown(view) }
            } else if let underlay = Underlay(tabBar: tbc.tabBar, chat: chatPage, bar: barPage) {
                ride = .underlay(underlay)
            } else {
                ride = .tracked
            }
            tabBarLog.debug("start push=\(self.isPush) hideAtEnd=\(self.hideAtEnd) ride=\(self.rideName, privacy: .public)")
            tick()
            let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        private var rideName: String {
            switch ride {
            case .underlay(let underlay): underlay.isSnapshot ? "snapshot" : "tabBar"
            case .tracked: "tracked"
            }
        }

        /// The bar in place and the pages' safe areas up to date with it.
        private func layOut() {
            tbc.view.setNeedsLayout()
            tbc.view.layoutIfNeeded()
            nav.view.setNeedsLayout()
            nav.view.layoutIfNeeded()
        }

        func tick() {
            guard !finished else { return }
            holdChatSafeArea()
            switch ride {
            case .underlay(let underlay):
                underlay.keep()
                // A bar shown again materializes; here it should simply be there.
                BarVisual.removeAnimations(underlay.view)
            case .tracked:
                track()
            }
        }

        /// Keeps the chat page's safe area at its bar-less value: what the bar adds is taken
        /// back with a negative additional inset. Measured on the chat page once it is in the
        /// window, else on the page with the bar.
        private func holdChatSafeArea() {
            guard let window = nav.view.window else { return }
            let page = chatPage.view.window != nil ? chatPage : barPage
            let extra = BarVisual.extraInsets(of: page, in: window)
            let held = UIEdgeInsets(
                top: savedChatInsets.top,
                left: savedChatInsets.left - extra.left,
                bottom: savedChatInsets.bottom - extra.bottom,
                right: savedChatInsets.right - extra.right
            )
            if chatPage.additionalSafeAreaInsets != held {
                tabBarLog.debug("hold chat safe area: bar adds \(NSCoder.string(for: extra), privacy: .public)")
                chatPage.additionalSafeAreaInsets = held
            }
        }

        /// Leaves the bar where it is and cuts out the page above it.
        private func track() {
            guard let window = nav.view.window else { return }
            let cover: CGRect? = topPage === barPage ? nil : BarVisual.presentationFrame(of: topPage.view, in: window)
            let views = BarVisual.views(in: tbc)
            for view in tracked where !views.contains(view) { BarVisual.reset(view) }
            tracked = views
            for view in views {
                // A bar shown again (the Duo's floating bar is re-inserted) materializes with a
                // blur-in; here it should simply be there.
                BarVisual.removeAnimations(view)
                BarVisual.place(view, cover: cover, in: window)
            }
        }

        func finish(cancelled: Bool) {
            guard !finished else { return }
            finished = true
            link?.invalidate()
            link = nil
            // On top now: the destination, or the source again after a cancelled swipe.
            let chatOnTop = cancelled ? !hideAtEnd : hideAtEnd
            tabBarLog.debug("finish cancelled=\(cancelled) hidden=\(chatOnTop)")
            switch ride {
            case .underlay(let underlay):
                underlay.restore()
                // Out of sight until UIKit has taken it away, so it never flashes back at rest.
                if chatOnTop && !underlay.isSnapshot { BarVisual.hideUntilShown(underlay.view) }
            case .tracked:
                if chatOnTop {
                    for view in tracked { BarVisual.hideUntilShown(view) }
                }
                for view in tracked { BarVisual.reset(view) }
                tracked = []
            }
            if !chatOnTop { BarVisual.restoreHidden() }
            tbc.setTabBarHidden(chatOnTop, animated: false)
            chatPage.additionalSafeAreaInsets = savedChatInsets
        }
    }

    /// `CADisplayLink` retains its target; this keeps the driver free of a cycle.
    @MainActor final class LinkTarget: NSObject {
        weak var driver: Driver?
        init(_ driver: Driver) { self.driver = driver }
        @objc func tick() { driver?.tick() }
    }
}

/// The bar kept still on screen between the two pages for one transition: above the page that
/// has it, below the chat page, which covers it as it slides in and reveals it as it slides
/// out. Like a bar that is part of the screen underneath, it never moves, fades or scales.
/// Normally a picture of the bar (`BarPicture`); the tab bar itself is the fallback, but
/// moved out of its container its glass draws washed out. Its glass also ignores a mask, so
/// it is placed in the page stack rather than cut out.
@MainActor
private final class Underlay {
    let view: UIView
    let isSnapshot: Bool
    private let rectInWindow: CGRect
    private weak var chat: UIViewController?
    private weak var other: UIViewController?
    private weak var container: UIView?
    private var index = 0
    private var containerFrame: CGRect = .zero

    /// The tab bar itself, when it draws inside `UITabBar` (along the bottom) and is placed by frame.
    init?(tabBar bar: UITabBar, chat: UIViewController, bar barPage: UIViewController) {
        bar.layoutIfNeeded()
        guard let window = bar.window,
              let container = bar.superview,
              !bar.isHidden, !bar.subviews.isEmpty,
              bar.bounds.width > bar.bounds.height, bar.bounds.height > 0,
              bar.translatesAutoresizingMaskIntoConstraints,
              !container.constraints.contains(where: { $0.firstItem === bar || $0.secondItem === bar })
        else { return nil }
        view = bar
        isSnapshot = false
        rectInWindow = container.convert(bar.frame, to: window)
        self.chat = chat
        other = barPage
        self.container = container
        index = container.subviews.firstIndex(of: bar) ?? container.subviews.count
        containerFrame = bar.frame
        keep()
    }

    /// A picture of the bar, put where the bar is on screen.
    init?(picture: BarPicture, chat: UIViewController, bar barPage: UIViewController) {
        view = picture.view
        isSnapshot = true
        rectInWindow = picture.rect
        self.chat = chat
        other = barPage
        keep()
    }

    /// Just below the chat page's branch of the view that holds both pages, at the same place
    /// on screen. Until both pages are in that view (the incoming one is added when the
    /// transition starts) the bar stays where it was.
    func keep() {
        guard let chatView = chat?.viewIfLoaded, let otherView = other?.viewIfLoaded,
              let window = chatView.window, otherView.window === window else { return }
        var branch: UIView = chatView
        while let parent = branch.superview {
            if otherView.isDescendant(of: parent) {
                UIView.performWithoutAnimation {
                    if view.superview !== parent || parent.subviews.firstIndex(of: view) != (parent.subviews.firstIndex(of: branch) ?? 0) - 1 {
                        parent.insertSubview(view, belowSubview: branch)
                    }
                    let frame = parent.convert(rectInWindow, from: window)
                    if view.frame != frame { view.frame = frame }
                }
                return
            }
            branch = parent
        }
    }

    func restore() {
        UIView.performWithoutAnimation {
            if isSnapshot {
                view.removeFromSuperview()
            } else if let container {
                container.insertSubview(view, at: min(index, container.subviews.count))
                view.frame = containerFrame
                container.setNeedsLayout()
            }
        }
    }
}

/// The bar's glass as it looks at rest on its page, cut to its capsule: a picture that can be
/// put between the pages when the real bar cannot (its glass draws only in its own container,
/// and on pop it is not drawn at all until the transition starts). Kept per page with the bar,
/// taken when that page is left, so popping back can show the bar from the first frame.
@MainActor
private final class BarPicture {
    let view: UIView
    /// Window coordinates.
    let rect: CGRect
    private let windowSize: CGSize

    private static let rim: CGFloat = 3
    private static let byPage = NSMapTable<UIViewController, BarPicture>.weakToStrongObjects()

    /// What the bar's views show on screen now.
    init?(of views: [UIView]) {
        guard let window = views.first?.window,
              // A few points more for the glass rim, drawn just outside the capsule's views.
              let capsule = BarVisual.capsule(of: views, in: window)?.insetBy(dx: -BarPicture.rim, dy: -BarPicture.rim)
                  .intersection(window.bounds),
              !capsule.isEmpty,
              let snapshot = window.resizableSnapshotView(from: capsule, afterScreenUpdates: false, withCapInsets: .zero)
        else { return nil }
        snapshot.isUserInteractionEnabled = false
        // Only the glass: the page around it moves on its own.
        snapshot.layer.cornerRadius = min(capsule.width, capsule.height) / 2
        snapshot.layer.cornerCurve = .continuous
        snapshot.layer.masksToBounds = true
        view = snapshot
        rect = capsule
        windowSize = window.bounds.size
    }

    static func store(_ picture: BarPicture, for page: UIViewController) {
        byPage.setObject(picture, forKey: page)
    }

    /// The picture taken when `page` was left, if the bar is still where it was then.
    static func stored(for page: UIViewController, matching views: [UIView]) -> BarPicture? {
        guard let picture = byPage.object(forKey: page),
              let window = views.first?.window, window.bounds.size == picture.windowSize,
              let capsule = BarVisual.capsule(of: views, in: window)?.insetBy(dx: -rim, dy: -rim)
                  .intersection(window.bounds),
              abs(capsule.minX - picture.rect.minX) < 1, abs(capsule.minY - picture.rect.minY) < 1,
              abs(capsule.width - picture.rect.width) < 1, abs(capsule.height - picture.rect.height) < 1
        else { return nil }
        return picture
    }
}

/// The views that draw the tab bar, and moving them.
@MainActor
private enum BarVisual {
    private static let hiddenByUs = NSHashTable<UIView>.weakObjects()

    /// The bar's on-screen views. The horizontal bar draws inside `UITabBar`; the floating
    /// one (iPhone Duo folded: a vertical bar on the trailing edge) draws its glass outside
    /// it, so those are found by their platter.
    static func views(in tbc: UITabBarController) -> [UIView] {
        let bar = tbc.tabBar
        if bar.window != nil, !bar.isHidden, !bar.subviews.isEmpty, bar.bounds.width > 0, bar.bounds.height > 0 {
            return [bar]
        }
        let root = tbc.view!
        var found: [UIView] = []
        func walk(_ view: UIView) {
            let name = String(describing: type(of: view))
            if name.contains("TabBarItemPlatter") || name.contains("TabBarExpansionPlatter") {
                // The outermost ancestor that is still only the bar (not a full-screen layer).
                var target = view
                while let parent = target.superview, parent !== root,
                      parent.bounds.width > 0, parent.bounds.height > 0,
                      parent.bounds.width < root.bounds.width || parent.bounds.height < root.bounds.height,
                      parent.bounds.width < root.bounds.width * 0.9 || parent.bounds.height < root.bounds.height * 0.9 {
                    target = parent
                }
                if !found.contains(target) { found.append(target) }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// The bar's glass capsule in window coordinates. The horizontal bar is a full-width
    /// strip with the capsule inside; the floating bar's views are the capsule.
    static func capsule(of views: [UIView], in window: UIWindow) -> CGRect? {
        guard !views.isEmpty else { return nil }
        if views.count == 1, let bar = views.first as? UITabBar {
            let strip = bar.convert(bar.bounds, to: window)
            var best: CGRect?
            func walk(_ view: UIView) {
                for sub in view.subviews where !sub.isHidden && sub.alpha > 0.01 {
                    let r = sub.convert(sub.bounds, to: window)
                    if r.height >= 30, r.height <= strip.height, r.width >= r.height * 1.5,
                       r.width < strip.width * 0.97, r.width * r.height > (best.map { $0.width * $0.height } ?? 0) {
                        best = r
                    }
                    walk(sub)
                }
            }
            walk(bar)
            tabBarLog.debug("capsule \(NSCoder.string(for: best ?? .null), privacy: .public) in \(NSCoder.string(for: strip), privacy: .public)")
            return best
        }
        var rect = CGRect.null
        for view in views { rect = rect.union(view.convert(view.bounds, to: window)) }
        return rect.isNull ? nil : rect
    }

    /// What the bar adds to `page`'s safe area beyond the window's insets and the page's own
    /// additional insets: the bottom when the bar is horizontal, nothing for the Duo's
    /// trailing column (that edge is inset anyway).
    static func extraInsets(of page: UIViewController, in window: UIWindow) -> UIEdgeInsets {
        let natural = page.view.safeAreaInsets
        let own = page.additionalSafeAreaInsets
        let base = window.safeAreaInsets
        return UIEdgeInsets(
            top: 0,
            left: max(natural.left - own.left - base.left, 0),
            bottom: max(natural.bottom - own.bottom - base.bottom, 0),
            right: max(natural.right - own.right - base.right, 0)
        )
    }

    static func presentationFrame(of view: UIView, in window: UIWindow) -> CGRect {
        guard let layer = view.layer.presentation(), let windowLayer = window.layer.presentation() else {
            return view.convert(view.bounds, to: window)
        }
        return layer.convert(layer.bounds, to: windowLayer)
    }

    /// Cuts out `cover` (window coordinates) from `view`.
    static func place(_ view: UIView, cover: CGRect?, in window: UIWindow) {
        guard let cover, let superview = view.superview else {
            view.layer.mask = nil
            return
        }
        let origin = superview.convert(
            CGPoint(x: view.center.x - view.bounds.width / 2, y: view.center.y - view.bounds.height / 2),
            to: window
        )
        var hole = cover.offsetBy(dx: -origin.x, dy: -origin.y)
        hole.origin.x += view.bounds.minX
        hole.origin.y += view.bounds.minY
        let mask = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = UIBezierPath(rect: view.bounds.insetBy(dx: -400, dy: -400))
        path.append(UIBezierPath(rect: hole))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.fillRule = .evenOdd
        mask.path = path.cgPath
        mask.frame = view.layer.bounds
        CATransaction.commit()
        view.layer.mask = mask
    }

    static func removeAnimations(_ view: UIView) {
        func strip(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.sublayers?.forEach(strip)
        }
        strip(view.layer)
    }

    static func reset(_ view: UIView) {
        view.transform = .identity
        view.layer.mask = nil
    }

    static func hideUntilShown(_ view: UIView) {
        guard !view.isHidden else { return }
        view.isHidden = true
        hiddenByUs.add(view)
    }

    static func restoreHidden() {
        for view in hiddenByUs.allObjects { view.isHidden = false }
        hiddenByUs.removeAllObjects()
    }
}
