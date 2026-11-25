import SwiftUI
import UIKit

/// One viewer page (31, 31b): a `UIScrollView` zooming its image 1–4× (bouncing past either
/// end), double tap 1× ↔ 2.5× at the tapped point, a single tap that waits for the double tap
/// to fail, and the swipe-down to close (only at 1×, by the 0.7 rule).
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    /// Not the page shown: its zoom goes back to 1×.
    let isCurrent: Bool
    var reduceMotion = false
    let onZoomChange: (Bool) -> Void
    let onSingleTap: () -> Void
    /// The swipe-down: translation, velocity, and whether the finger lifted.
    let onDismissDrag: (CGSize, CGPoint, Bool) -> Void

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.callbacks = context.coordinator
        context.coordinator.view = view
        view.setImage(image, animated: false)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
        view.reduceMotion = reduceMotion
        if view.imageView.image !== image {
            view.setImage(image, animated: view.imageView.image != nil)
        }
        if !isCurrent, view.zoomScale != 1 {
            view.setZoomScale(1, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator {
        var parent: ZoomableImageView
        weak var view: ZoomScrollView?
        private var zoomed = false

        init(parent: ZoomableImageView) {
            self.parent = parent
        }

        func zoomChanged(_ scale: CGFloat) {
            let now = scale > 1.01
            guard now != zoomed else { return }
            zoomed = now
            parent.onZoomChange(now)
        }

        func singleTap() { parent.onSingleTap() }

        func dismissDrag(_ translation: CGPoint, _ velocity: CGPoint, ended: Bool) {
            parent.onDismissDrag(CGSize(width: translation.x, height: translation.y), velocity, ended)
        }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var reduceMotion = false
    weak var callbacks: ZoomableImageView.Coordinator?
    private var lastBounds: CGSize = .zero
    private let dismissPan = UIPanGestureRecognizer()
    private let dismissRule = DismissPanRule()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        dismissPan.addTarget(self, action: #selector(panned(_:)))
        dismissRule.scrollView = self
        dismissPan.delegate = dismissRule
        addGestureRecognizer(dismissPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage?, animated: Bool) {
        if animated, !reduceMotion {
            UIView.transition(with: imageView, duration: 0.15, options: .transitionCrossDissolve) {
                self.imageView.image = image
            }
        } else {
            imageView.image = image
        }
        layoutImage(force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutImage(force: false)
    }

    /// At 1× the image is fitted to the page; zoomed, only the centering insets change.
    private func layoutImage(force: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if (force || bounds.size != lastBounds), zoomScale == 1 {
            lastBounds = bounds.size
            let size = imageView.image?.size ?? CGSize(width: 4, height: 3)
            let fit = ImageViewerDismiss.fitted(size, in: CGRect(origin: .zero, size: bounds.size)).size
            imageView.frame = CGRect(origin: .zero, size: fit)
            contentSize = fit
        }
        center()
    }

    private func center() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        callbacks?.zoomChanged(zoomScale)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        callbacks?.zoomChanged(scale)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: !reduceMotion)
        } else {
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: !reduceMotion)
        }
    }

    @objc private func singleTapped() {
        callbacks?.singleTap()
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: window)
        let velocity = gesture.velocity(in: window)
        switch gesture.state {
        case .changed:
            callbacks?.dismissDrag(translation, velocity, ended: false)
        case .ended, .cancelled, .failed:
            callbacks?.dismissDrag(translation, gesture.state == .ended ? velocity : .zero, ended: true)
        default:
            break
        }
    }
}

/// The swipe-down starts only at 1×, going down and at most 0.7× as far sideways; it runs
/// beside the page's own pan.
private final class DismissPanRule: NSObject, UIGestureRecognizerDelegate {
    weak var scrollView: UIScrollView?

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let scrollView, scrollView.zoomScale <= 1.01, let pan = gesture as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: scrollView)
        return ImageViewerDismiss.claims(dx: velocity.x, dy: velocity.y)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === scrollView?.panGestureRecognizer
    }
}
