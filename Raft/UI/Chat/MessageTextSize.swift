import SwiftUI

/// Settings › Appearance › Message text size (设置 · 消息字号). Only the text of messages follows it
/// (channels, DMs, threads, search results, Saved); lists, navigation and the composer do not.
/// System Text Size (Dynamic Type) still scales on top of the chosen level.
enum MessageTextSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    /// `@AppStorage` key; this device only.
    static let storageKey = "messageTextSize"

    var id: String { rawValue }

    /// The body size at the default system Text Size: SF Pro 15 / 16 / 17 (Large = the body the
    /// app shipped with). Line heights follow the face's own leading, in proportion.
    var bodySize: CGFloat {
        switch self {
        case .small: 15
        case .medium: 16
        case .large: 17
        }
    }

    /// Points from the Large body; search-result and Saved snippets move by the same step.
    var step: CGFloat { bodySize - MessageTextSize.large.bodySize }

    /// Search-result and Saved snippets: 13 / 14 / 15 (Large = the `subheadline` they had).
    var snippetSize: CGFloat { 15 + step }

    var title: String {
        switch self {
        case .small: L10n.t("ios_text_size_small", "Small")
        case .medium: L10n.t("ios_text_size_medium", "Medium")
        case .large: L10n.t("ios_text_size_large", "Large")
        }
    }

    /// The message body at this level. `scale` is the Dynamic Type factor for `.body`
    /// (`@ScaledMetric(relativeTo: .body)` 17 ÷ 17), so the system size scales on top.
    func bodyFont(scale: CGFloat = 1) -> RaftFont {
        RaftFont(name: RaftFont.regular, size: bodySize, relativeTo: .body, family: .system, systemScale: scale)
    }

    /// A message snippet (search results, Saved) at this level; `scale` is the `.subheadline` factor.
    func snippetFont(scale: CGFloat = 1) -> RaftFont {
        RaftFont(name: RaftFont.regular, size: snippetSize, relativeTo: .subheadline, family: .system, systemScale: scale)
    }
}

/// The level a new install starts at (the user chose Small).
let defaultMessageTextSize: MessageTextSize = .small

/// Message text at the chosen level, scaled by the system Text Size.
struct MessageFontModifier: ViewModifier {
    enum Role { case body, snippet }

    var role: Role
    @AppStorage(MessageTextSize.storageKey) private var level: MessageTextSize = defaultMessageTextSize
    @ScaledMetric(relativeTo: .body) private var scaledBody: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var scaledSubheadline: CGFloat = 15

    func body(content: Content) -> some View {
        switch role {
        case .body: content.raftFont(level.bodyFont(scale: scaledBody / 17))
        case .snippet: content.raftFont(level.snippetFont(scale: scaledSubheadline / 15))
        }
    }
}

extension View {
    /// Message text at the Settings level (see `MessageTextSize`).
    func messageFont(_ role: MessageFontModifier.Role = .body) -> some View {
        modifier(MessageFontModifier(role: role))
    }
}
