import QuickLook
import SwiftUI

// MARK: Long-press actions (§3-12)

/// One action in the long-press menu.
struct MessageMenuItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void
}

/// What the overlay lifts: the row, where it was, and what can be done with it.
struct MessageActionTarget: Identifiable {
    let id = UUID()
    let row: MessageRowModel
    let frame: CGRect
    let context: ChatContext
    /// Quick reactions are offered (sent messages only).
    var reactionsEnabled: Bool
    var items: [MessageMenuItem]
    var react: (String) -> Void
    var moreReactions: () -> Void
}

/// The state long-press, Quick Look, the emoji keyboard and the failure alert share on one
/// conversation screen.
@MainActor
@Observable
final class MessageInteractions {
    var target: MessageActionTarget?
    /// The message the emoji keyboard reacts to.
    var emojiMessageId: String?
    var emojiActive = false
    var previewURL: URL?
    var failureDetail: String?
    var showsFailureDetail = false
    var highlightedId: String?
    var liftCount = 0

    func present(_ target: MessageActionTarget) {
        liftCount += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.target = target }
    }

    func dismissOverlay() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { target = nil }
    }

    func pickEmoji(for messageId: String) {
        emojiMessageId = messageId
        emojiActive = true
    }

    func showFailure(_ reason: String) {
        failureDetail = reason
        showsFailureDetail = true
    }

    /// Highlights the focused message (search, Activity → message): held 1.2s, then the row
    /// fades it out over 0.8s (at once with Reduce Motion, `MessageRowView`).
    func flash(_ entryId: String) {
        highlightedId = entryId
        Task { [weak self] in
            try? await Task.sleep(for: Self.flashHold)
            guard self?.highlightedId == entryId else { return }
            self?.highlightedId = nil
        }
    }

    private static var flashHold: Duration {
        #if DEBUG
        // The design review screenshot of 29c needs the flash on screen.
        if PreviewGallery.screen == "29c" { return .seconds(600) }
        #endif
        return .milliseconds(1200)
    }
}

extension View {
    /// The long-press overlay, emoji keyboard, Quick Look and failure alert of a conversation.
    func messageInteractions(_ interactions: MessageInteractions, react: @escaping (String, String) -> Void) -> some View {
        modifier(MessageInteractionsModifier(interactions: interactions, react: react))
    }
}

private struct MessageInteractionsModifier: ViewModifier {
    @Bindable var interactions: MessageInteractions
    let react: (String, String) -> Void

    func body(content: Content) -> some View {
        content
            .background(alignment: .bottomLeading) {
                EmojiPickerField(isActive: $interactions.emojiActive) { emoji in
                    if let id = interactions.emojiMessageId { react(id, emoji) }
                    interactions.emojiMessageId = nil
                }
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
            }
            .fullScreenCover(item: $interactions.target) { target in
                MessageActionsOverlay(target: target) {
                    interactions.dismissOverlay()
                }
                .presentationBackground(.clear)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: interactions.liftCount)
            .quickLookPreview($interactions.previewURL)
            .alert(L10n.t("thread_send_failure_details", "Details"), isPresented: $interactions.showsFailureDetail) {
                Button(L10n.t("common_ok", "OK"), role: .cancel) {}
            } message: {
                Text(verbatim: L10n.f("thread_send_failure_summary", "Send failed: %1$@", interactions.failureDetail ?? ""))
            }
    }
}

/// Dim layer, quick reactions, the lifted message and the action menu.
struct MessageActionsOverlay: View {
    let target: MessageActionTarget
    let dismiss: () -> Void

    static let quickReactions = ["👍", "❤️", "🎉", "👀", "🔥", "😂"]

    @State private var shown = false
    @State private var cardHeight: CGFloat = 0
    @State private var menuHeight: CGFloat = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var windowInsets: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets ?? .zero
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = windowInsets
            let screen = proxy.size
            let layout = layout(screen: screen, insets: insets)
            ZStack(alignment: .topLeading) {
                dimLayer
                    .onTapGesture(perform: close)
                    .accessibilityAction(.escape, close)
                if target.reactionsEnabled {
                    reactionBar
                        .scaleEffect(shown ? 1 : 0.85, anchor: .bottomLeading)
                        .opacity(shown ? 1 : 0)
                        .padding(.leading, 20)
                        .offset(y: layout.cardTop - 66)
                }
                card(maxHeight: layout.cardMaxHeight)
                    .scaleEffect(shown ? 1.0 : 0.98, anchor: .center)
                    .padding(.horizontal, 10)
                    .offset(y: layout.cardTop)
                menu
                    .scaleEffect(shown ? 1 : 0.85, anchor: .topLeading)
                    .opacity(shown ? 1 : 0)
                    .padding(.leading, 20)
                    .offset(y: layout.cardTop + min(cardHeight, layout.cardMaxHeight) + 10)
            }
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2)) { shown = true }
        }
    }

    private struct Layout {
        var cardTop: CGFloat
        var cardMaxHeight: CGFloat
    }

    /// The card stays where the row was unless the bar or the menu would leave the screen.
    private func layout(screen: CGSize, insets: UIEdgeInsets) -> Layout {
        let menuSpace = (menuHeight > 0 ? menuHeight : CGFloat(target.items.count) * 46 + 12) + 10
        let minTop = target.reactionsEnabled ? max(92, insets.top + 72) : insets.top + 12
        let maxBottom = screen.height - max(menuSpace + 6, menuSpace + insets.bottom)
        let maxHeight = max(80, maxBottom - minTop)
        let height = min(cardHeight, maxHeight)
        var top = target.frame.minY - 14
        top = min(top, maxBottom - height)
        top = max(top, minTop)
        return Layout(cardTop: top, cardMaxHeight: maxHeight)
    }

    private var dimLayer: some View {
        Group {
            if reduceTransparency {
                Color.raftInk.opacity(0.45)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.raftInk.opacity(0.18))
            }
        }
        .opacity(shown ? 1 : 0)
        .ignoresSafeArea()
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.15)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            dismiss()
        }
    }

    // MARK: Pieces

    private var reactionBar: some View {
        let mine = Set(target.row.reactions.filter { $0.reactorIds.contains(target.context.currentUserId) }.map(\.emoji))
        return HStack(spacing: 2) {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                Button {
                    target.react(emoji)
                    close()
                } label: {
                    Text(verbatim: emoji)
                        .font(.system(size: 26))
                        .frame(width: 42, height: 42)
                        .background {
                            if mine.contains(emoji) { Circle().fill(Color.raftHighlight) }
                        }
                }
                .buttonStyle(EmojiPressStyle())
                .accessibilityLabel(Text(verbatim: emoji))
                .accessibilityAddTraits(mine.contains(emoji) ? .isSelected : [])
            }
            Button {
                close()
                target.moreReactions()
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.raftTextSecondary)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(EmojiPressStyle())
            .accessibilityLabel(Text(L10n.t("thread_action_add_reaction", "Add reaction")))
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .raftGlass(Capsule(), interactive: true)
    }

    private func card(maxHeight: CGFloat) -> some View {
        MessageRowView(
            row: target.row,
            context: target.context,
            showsAddReaction: false,
            interactive: false,
            horizontalPadding: 14
        )
        .allowsHitTesting(false)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
        // Hug the message: a flexible `maxHeight` frame would take the whole proposed height.
        .frame(height: cardHeight > 0 ? min(cardHeight, maxHeight) : nil, alignment: .top)
        .clipped()
        .background(Color.raftCanvas, in: .rect(cornerRadius: 20, style: .continuous))
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.16), radius: 24, y: 10)
        .accessibilityHidden(true)
    }

    private var menu: some View {
        VStack(spacing: 0) {
            ForEach(target.items) { item in
                Button {
                    close()
                    item.action()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20))
                            .frame(width: 24)
                        Text(verbatim: item.title)
                            .raftFont(.rowTitleMedium)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(item.destructive ? Color.raftDanger : Color.raftTextPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .contentShape(.rect(cornerRadius: 16))
                }
                .buttonStyle(MenuRowStyle())
                .accessibilityIdentifier("message-action-\(item.id)")
            }
        }
        .padding(6)
        .frame(width: 250)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
        .raftGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct EmojiPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.raftInk.opacity(configuration.isPressed ? 0.07 : 0)))
            .scaleEffect(configuration.isPressed ? 1.12 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.raftTextPrimary.opacity(configuration.isPressed ? 0.07 : 0)))
    }
}

// MARK: Links

enum Permalink {
    /// `https://<web>/s/<server>/channel|dm/<channelId>?msg=<id>` (a reply adds
    /// `thread=<threadChannelId>:<parentId>`), as the web app builds them.
    static func message(base: URL, serverSlug: String?, channelId: String, isDirectMessage: Bool, messageId: String, thread: (channelId: String, parentId: String)? = nil) -> URL {
        var url = base
        if let serverSlug, !serverSlug.isEmpty { url = url.appending(path: "s/\(serverSlug)") }
        url = url.appending(path: "\(isDirectMessage ? "dm" : "channel")/\(channelId)")
        var items: [URLQueryItem] = []
        if let thread { items.append(URLQueryItem(name: "thread", value: "\(thread.channelId):\(thread.parentId)")) }
        items.append(URLQueryItem(name: "msg", value: messageId))
        return url.appending(queryItems: items)
    }
}
