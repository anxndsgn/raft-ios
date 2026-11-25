import SwiftUI

// MARK: 12c SavedMark

/// The saved message's header mark: an 18pt yellow sticker with a filled bookmark (not a button).
struct SavedMark: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Image(systemName: "bookmark.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.raftInk)
            .frame(width: 18, height: 18)
            .background(Color.raftYellow, in: shape)
            .overlay(shape.strokeBorder(Color.raftInk, lineWidth: 1.5))
            .dieCut()
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// In with a small spring (0.6 → 1), out with a 0.15s fade (13.2).
    static var transition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.6).combined(with: .opacity).animation(.spring(duration: 0.25, bounce: 0.3)),
            removal: .opacity.animation(.easeOut(duration: 0.15))
        )
    }
}

// MARK: 12b Save / Remove from Saved

extension SavedStore {
    /// The long-press item for a sent message (row 2, after Reply in thread); nil for a deleted one.
    /// Pending and failed sends have their own menu, and previews do not ask for it.
    func menuItem(for message: Message) -> MessageMenuItem? {
        guard !message.isDeleted else { return nil }
        let saved = isSaved(message.id)
        return MessageMenuItem(
            id: "save",
            title: Self.actionTitle(saved: saved),
            systemImage: saved ? "bookmark.slash" : "bookmark"
        ) { [weak self] in
            Task { await self?.setSaved(message.id, !saved) }
        }
    }

    /// The VoiceOver action of a row (nil where the menu has no Save item).
    func toggleAction(for message: Message) -> (() -> Void)? {
        guard !message.isDeleted else { return nil }
        return { [weak self] in
            Task { await self?.toggle(message.id) }
        }
    }

    static func actionTitle(saved: Bool) -> String {
        saved
            ? L10n.t("thread_action_remove_from_saved", "Remove from Saved")
            : L10n.t("thread_action_save_message", "Save")
    }
}

// MARK: Checks and feedback

extension View {
    /// Asks which of the shown messages are saved whenever a page of them loads (12c).
    func savedChecks(_ store: SavedStore, ids: [String], page: String?) -> some View {
        task(id: page) {
            guard page != nil else { return }
            await store.check(ids)
        }
    }

    /// The haptic, VoiceOver announcement and toast of a finished save or removal (13.2).
    func savedFeedback(_ store: SavedStore, model: AppModel) -> some View {
        modifier(SavedFeedbackModifier(store: store, model: model))
    }
}

private struct SavedFeedbackModifier: ViewModifier {
    let store: SavedStore
    let model: AppModel
    @State private var successTick = 0
    @State private var errorTick = 0

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.success, trigger: successTick)
            .sensoryFeedback(.error, trigger: errorTick)
            .onChange(of: store.feedback) { _, feedback in
                guard let feedback else { return }
                switch feedback.kind {
                case .saved:
                    successTick += 1
                    AccessibilityNotification.Announcement(L10n.t("thread_label_saved", "Saved")).post()
                case .removed:
                    successTick += 1
                    AccessibilityNotification.Announcement(L10n.t("ios_saved_removed_announcement", "Removed from Saved")).post()
                case .saveFailed:
                    errorTick += 1
                    model.showToast(L10n.t("thread_error_save_message", "Unable to save message"), duration: .seconds(3))
                case .removeFailed:
                    errorTick += 1
                    model.showToast(L10n.t("thread_error_remove_saved_message", "Unable to remove saved message"), duration: .seconds(3))
                case .unavailable:
                    model.showToast(L10n.t("ios_saved_message_unavailable", "This message is no longer available."), duration: .seconds(3))
                case .readOnly:
                    model.showToast(StoreError.readOnly.errorDescription ?? "")
                }
            }
    }
}
