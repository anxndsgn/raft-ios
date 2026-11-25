import SwiftUI

// Controls and containers (§2.13–2.19).

// MARK: Buttons

/// The pink glass capsule (Sign in, Verify, Open Raft on the web). Loading keeps it pink.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.raftInk)
                } else {
                    if let systemImage { Image(systemName: systemImage).font(.system(size: 20)) }
                    Text(verbatim: title).raftFont(.buttonLabel)
                }
            }
            .foregroundStyle(Color.raftInk)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(.raftPink)
        .allowsHitTesting(!isLoading)
    }
}

/// The glass capsule secondary button (52 or 44 high).
struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: compact ? 18 : 20)) }
                Text(verbatim: title).raftFont(compact ? .buttonLabelSmall : .buttonLabelSecondary)
            }
            .foregroundStyle(Color.raftTextPrimary)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 44 : 52)
            .padding(.horizontal, compact ? 18 - 12 : 0)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }
}

/// Pressed rows tint `raftTextPrimary@6%` (no List selection style).
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.raftTextPrimary.opacity(0.06) : Color.clear)
    }
}

/// Pressed solid cards darken slightly.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: Cards

/// A solid group card holding rows separated by inset hairlines (§2.13).
struct RaftGroupCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .raftCardSurface(.card)
            .padding(.horizontal, 16)
    }
}

/// The 0.5pt separator between card rows, inset from the leading edge.
struct RowDivider: View {
    var inset: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.raftHairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// A settings-style row: icon, title, value, chevron (§2.13 `SettingsRow` / `ActionRow`).
struct SettingsRowLabel: View {
    let systemImage: String
    let title: String
    var value: String?
    var valueMono = false
    var chevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.raftTextSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .raftFont(.rowTitleMedium)
                .foregroundStyle(Color.raftTextPrimary)
            Spacer(minLength: 8)
            if let value {
                Text(verbatim: value)
                    .font(valueMono ? .custom(RaftFont.mono, size: 15, relativeTo: .subheadline) : RaftFont.callout.font)
                    .foregroundStyle(Color.raftTextTertiary)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.raftTextDisabled)
                    .padding(.leading, value == nil ? 0 : -8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

// MARK: Field (§2.19)

struct RaftField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var isSecure = false
    var error: String?
    var mono = false
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}
    var focus: FocusState<Bool>.Binding

    @State private var reveal = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: label)
                .raftFont(.footnoteStrong)
                .foregroundStyle(Color.raftTextSecondary)
                .padding(.leading, 4)
                .padding(.bottom, 6)
            HStack(spacing: 8) {
                Group {
                    if isSecure && !reveal {
                        SecureField(text: $text) { Text(verbatim: placeholder).foregroundStyle(Color.raftTextTertiary) }
                    } else {
                        TextField(text: $text) { Text(verbatim: placeholder).foregroundStyle(Color.raftTextTertiary) }
                    }
                }
                .font(mono ? RaftFont.monoField.font : RaftFont.body.font)
                .tracking(mono ? 0.68 : 0)
                .foregroundStyle(Color.raftTextPrimary)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .focused(focus)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityValue(error.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
                if isSecure {
                    Button {
                        reveal.toggle()
                    } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.raftTextSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? L10n.t("common_hide_password", "Hide password") : L10n.t("common_show_password", "Show password"))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, isSecure ? 4 : 14)
            .frame(height: 52)
            .background(error != nil ? Color.raftErrorFieldBG : Color.raftFieldFill, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(ring)
            .background(glow)
            if let error {
                ErrorLine(text: error).padding(.top, 8)
            }
        }
    }

    private var ring: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let color: Color = error != nil ? .raftRed : (focus.wrappedValue ? .raftTextPrimary : .raftFieldRing)
        return shape.strokeBorder(color, lineWidth: error != nil || focus.wrappedValue ? 1.5 : 1)
    }

    @ViewBuilder private var glow: some View {
        if error != nil || focus.wrappedValue {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(error != nil ? Color.raftRed.opacity(0.14) : Color.raftYellow.opacity(0.35))
                .padding(-4)
        }
    }
}

/// `exclamationmark.circle` + danger text, indented 4 (§2.19).
struct ErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 15))
            Text(verbatim: text).raftFont(.errorText)
        }
        .foregroundStyle(Color.raftDanger)
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
    }
}

/// An 18pt checkbox (terms, As task).
struct RaftCheckbox: View {
    let isOn: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        shape
            .fill(isOn ? Color.raftYellow : (scheme == .dark ? Color.clear : Color.white.opacity(0.6)))
            .overlay(shape.strokeBorder(scheme == .dark && !isOn ? Color.raftTextPrimary : Color.raftInk, lineWidth: 1.5))
            .overlay {
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.raftInk)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

// MARK: Skeleton (§2.14)

struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.raftSkeleton)
            .frame(width: width, height: height)
    }
}

// MARK: Banner (§2.15)

struct StatusBanner: View {
    let updatedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.raftCyan)
            Text(L10n.t("ios_reconnecting", "Reconnecting…"))
                .raftFont(.grotesk(RaftFont.semibold, 14, relativeTo: .subheadline))
                .foregroundStyle(Color.raftTextPrimary)
            Spacer(minLength: 8)
            if let updatedAt {
                Text(verbatim: L10n.f("ios_updated_at", "Updated %1$@", RaftFormat.clock(updatedAt)))
                    .raftFont(.monoCaption)
                    .foregroundStyle(Color.raftTextTertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .raftGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status-banner")
    }
}

// MARK: Empty state (§2.17)

struct EmptyStateView<Art: View, Actions: View>: View {
    let title: String
    var detail: String?
    var top: CGFloat = 72
    var horizontal: CGFloat = 32
    @ViewBuilder var art: () -> Art
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            art()
                .padding(.bottom, 20)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .raftFont(.emptyTitle)
                .foregroundStyle(Color.raftTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            if let detail {
                Text(verbatim: detail)
                    .raftFont(.callout)
                    .foregroundStyle(Color.raftTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 20)
            }
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, horizontal)
        .padding(.top, top)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, detail: String? = nil, top: CGFloat = 72, horizontal: CGFloat = 32, @ViewBuilder art: @escaping () -> Art) {
        self.init(title: title, detail: detail, top: top, horizontal: horizontal, art: art) { EmptyView() }
    }
}

/// A square illustration sticker with an SF symbol and a hard shadow.
struct IllustrationSticker: View {
    let systemImage: String
    var color: Color
    var side: CGFloat = 64
    var symbolSize: CGFloat = 28
    var shadow: CGFloat = 3

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.raftInk, lineWidth: 1.5))
            .overlay { Image(systemName: systemImage).font(.system(size: symbolSize, weight: .heavy)).foregroundStyle(Color.raftInk) }
            .frame(width: side, height: side)
            .dieCut()
            .hardShadow(shadow)
    }
}

/// The generic load failure: red sticker, title, Retry.
struct LoadErrorView: View {
    let title: String
    var detail: String?
    var top: CGFloat = 72
    let retry: () -> Void

    var body: some View {
        EmptyStateView(title: title, detail: detail, top: top) {
            IllustrationSticker(systemImage: "exclamationmark", color: .raftRed)
        } actions: {
            SecondaryButton(title: L10n.t("common_retry", "Retry"), compact: true, action: retry)
                .accessibilityIdentifier("retry-button")
        }
    }
}

/// The "all caught up" sticker (lime check, 4pt hard shadow).
struct AllReadSticker: View {
    var body: some View {
        IllustrationSticker(systemImage: "checkmark", color: .raftLime, side: 72, symbolSize: 32, shadow: 4)
    }
}
