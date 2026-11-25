import SwiftUI
import UIKit

// Pieces shared by New message (28) and message search (29).

/// A card's single error row (the inline retry row of §11-25): `exclamationmark.circle` 15
/// raftDanger, the text, an underlined Retry (a spinner while retrying). The whole row retries.
struct SearchRetryRow: View {
    let title: String
    var isRetrying = false
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.raftDanger)
                Text(verbatim: title)
                    .raftFont(.rowTitleMedium)
                    .foregroundStyle(Color.raftTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isRetrying {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.t("common_retry", "Retry"))
                        .font(.custom(RaftFont.semibold, size: 15, relativeTo: .subheadline))
                        .underline(true, color: Color.raftTextPrimary)
                        .foregroundStyle(Color.raftTextPrimary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(isRetrying)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(isRetrying ? Text(L10n.t("ios_loading", "Loading")) : Text(verbatim: ""))
        .accessibilityHint(Text(L10n.t("common_retry", "Retry")))
    }
}

/// The centered "nothing matches" block (28c, 29d): `magnifyingglass` 32, SG Bold 20/26 title,
/// `preview` detail.
struct SearchEmptyBlock: View {
    let title: String
    let detail: String
    /// From the top of the scroll content to the block (the block's top sits at y=268).
    var top: CGFloat

    private static let titleFont = RaftFont(name: RaftFont.bold, size: 20, lineHeight: 26, relativeTo: .title3)

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.raftTextTertiary)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .raftFont(Self.titleFont)
                .foregroundStyle(Color.raftTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
            Text(verbatim: detail)
                .raftFont(.preview)
                .foregroundStyle(Color.raftTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, top)
        .accessibilityElement(children: .combine)
    }
}

/// The "Agent" tag after an agent's runtime (§2.9).
struct PersonAgentTag: View {
    var body: some View {
        Text(L10n.t("composer_mention_actor_agent", "Agent"))
            .raftFont(.monoSmall)
            .foregroundStyle(Color.raftTextSecondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.raftDivider, lineWidth: 1))
            .fixedSize()
    }
}

/// Bare icon buttons on content (the DM header's new-message pencil): dim to 0.5 while pressed.
struct DimOnPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1)
    }
}

enum KeyboardDismissal {
    /// Puts the keyboard away (whichever field holds it), without ending a search.
    @MainActor static func now() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension Text {
    /// The parts as one `Text`, each keeping its own styling (`+` is deprecated in iOS 26). The
    /// interpolation is built at runtime, so no "%@%@" key reaches the String Catalog, and that
    /// key is not in it: the parts show as they are.
    static func joined(_ parts: [Text]) -> Text {
        var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: parts.count)
        for part in parts {
            interpolation.appendInterpolation(part)
        }
        return Text(LocalizedStringKey(stringInterpolation: interpolation))
    }
}
