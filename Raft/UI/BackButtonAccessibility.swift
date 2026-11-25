import SwiftUI
import UIKit

extension View {
    /// Names the system back button for VoiceOver on a pushed page: "Back" (localized), a button.
    /// In the vertical bar (iPhone Duo folded, unfolded landscape; iOS 27.1) the system's
    /// `BackButton` element has no label and no button trait. Set again on every appearance and
    /// size-class change, when the bar may have rebuilt it.
    func backButtonAccessibility() -> some View {
        background {
            BackButtonLabeler()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct BackButtonLabeler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (controller: Controller, _) in
                controller.label()
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            label()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            label()
        }

        /// Now and once the bar has settled (its buttons are swapped during the transition).
        private func label() {
            BackButtonLabel.apply(near: view)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                BackButtonLabel.apply(near: self.view)
            }
        }
    }
}

@MainActor
enum BackButtonLabel {
    static let identifier = "BackButton"

    static func apply(near view: UIView) {
        guard let window = view.window else { return }
        let label = L10n.t("ios_back", "Back")
        for window in window.windowScene?.windows ?? [window] {
            visit(window, label: label)
        }
    }

    private static func visit(_ view: UIView, label: String) {
        if view.accessibilityIdentifier == identifier { set(view, label: label) }
        for case let element as NSObject in view.accessibilityElements ?? [] {
            if (element as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier {
                set(element, label: label)
            }
        }
        for subview in view.subviews { visit(subview, label: label) }
    }

    private static func set(_ element: NSObject, label: String) {
        if element.accessibilityLabel != label { element.accessibilityLabel = label }
        if !element.accessibilityTraits.contains(.button) { element.accessibilityTraits.insert(.button) }
    }
}
