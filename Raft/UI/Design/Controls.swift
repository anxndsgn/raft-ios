import SwiftUI

// Controls and containers (§2.13–2.19).

// MARK: Buttons

/// The pink glass capsule (Sign in, Verify, Open Raft on the web). Loading keeps it pink.
/// Measures 52 (§2.18, XIN 5467): the glass is drawn by `GlassCapsuleButtonStyle`, which adds
/// nothing around the label (the system `.glassProminent` put ~14 above and below a 52 label).
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    let action: () -> Void

    static let height: CGFloat = 52

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
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: Self.height)
        }
        .buttonStyle(GlassCapsuleButtonStyle(tint: .raftPink))
        .allowsHitTesting(!isLoading)
    }
}

/// The glass capsule secondary button, 52 or 44 high as measured (same style as `PrimaryButton`).
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
            .padding(.horizontal, compact ? 18 : 20)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 44 : 52)
        }
        .buttonStyle(GlassCapsuleButtonStyle())
    }
}

/// A capsule button whose outer frame is its label's frame: a solid capsule, pink when `tint`
/// is set (the primary), white otherwise. No glass: the system glass's own shadow read as a
/// card shadow on the sign-in page (§1.5, Colo); the buttons sit on the plain canvas, where
/// glass showed nothing through anyway.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .modifier(GlassCapsuleSurface(tint: tint))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GlassCapsuleSurface: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        content.background(tint ?? Color.raftCard, in: Capsule())
    }
}

/// A solid pink capsule that shrinks to 0.96 while pressed (Join channel, §26).
struct PinkPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.raftPink, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The row press highlight (§2.13): `raftTextPrimary@6%`, a square fill over the whole row —
/// only the group card's clip rounds it, so a first row has rounded top corners, a last row
/// rounded bottom ones and a middle row none. Never the system List / menu selection platter.
///
/// Like the system list it stays on after the tap while the row's destination is pushed and
/// fades out when the row comes back on screen (the pop). A tap that pushes nothing (a toggle,
/// a dialog, a sheet) lets it go after a moment.
///
/// A `PrimitiveButtonStyle` (it must see the tap), drawing an ordinary `Button`: VoiceOver
/// still reads a button, `.disabled` and roles pass through, and a scroll still cancels the press.
struct RowButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }
}

private struct RowButtonBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    /// Kept on after the tap until the pushed screen is popped (or nothing was pushed).
    @State private var latched = false
    /// The row left the screen while latched: its destination was pushed.
    @State private var pushed = false
    @State private var release: Task<Void, Never>?

    var body: some View {
        Button(role: configuration.role) {
            latch()
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(RowPressStyle(latched: latched))
        .onDisappear {
            if latched { pushed = true; release?.cancel() }
        }
        .onAppear {
            guard latched, pushed else { return }
            pushed = false
            withAnimation(.easeOut(duration: 0.35)) { latched = false }
        }
    }

    private func latch() {
        latched = true
        pushed = false
        release?.cancel()
        release = Task { @MainActor in
            // Longer than a push takes to cover the row; a push that started clears `release`.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, !pushed else { return }
            withAnimation(.easeOut(duration: 0.25)) { latched = false }
        }
    }
}

private struct RowPressStyle: ButtonStyle {
    let latched: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            // A view, not `background(_ style:)`: a style background takes the enclosing
            // container shape (the card's 16pt corners) and would round every row on its own.
            .background {
                if configuration.isPressed || latched {
                    Rectangle().fill(Color.raftRowPressed)
                }
            }
    }
}

extension Color {
    /// The pressed / selected row fill (§2.13): `raftTextPrimary@6%`, light and dark.
    static var raftRowPressed: Color { .raftTextPrimary.opacity(0.06) }
}

/// Where a row sits in its group card: which of the card's outer corners it carries.
struct RaftCardRowEdges: Equatable {
    var top = false
    var bottom = false

    /// The row's outline: square, except the card's own corners (radius 16, continuous).
    var shape: UnevenRoundedRectangle {
        let r: CGFloat = top || bottom ? RaftGroupCard<EmptyView>.radius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: top ? r : 0,
            bottomLeadingRadius: bottom ? r : 0,
            bottomTrailingRadius: bottom ? r : 0,
            topTrailingRadius: top ? r : 0,
            style: .continuous
        )
    }
}

extension EnvironmentValues {
    /// Set by `RaftGroupCard` on each of its rows; outside a card a row is square.
    @Entry var raftCardRowEdges = RaftCardRowEdges()
}

extension View {
    /// A row's long-press menu, its lifted preview shaped like the row (square, with the card's
    /// outer corners on a first / last row) — not the system's own rounded platter (§2.13).
    func raftRowContextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View {
        modifier(RaftRowMenuShape()).contextMenu(menuItems: menuItems)
    }
}

private struct RaftRowMenuShape: ViewModifier {
    @Environment(\.raftCardRowEdges) private var edges

    func body(content: Content) -> some View {
        content.contentShape(.contextMenuPreview, edges.shape)
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
/// Each row learns whether it is the card's first or last (`raftCardRowEdges`), for the shapes
/// the card's clip does not reach (a long-press menu preview).
struct RaftGroupCard<Content: View>: View {
    static var radius: CGFloat { 16 }

    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { rows in
                ForEach(rows) { row in
                    row.environment(\.raftCardRowEdges, RaftCardRowEdges(top: row.id == rows.first?.id, bottom: row.id == rows.last?.id))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
        .raftCardSurface()
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
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        HStack(alignment: ax ? .top : .center, spacing: 12) {
            SettingsRowIcon(systemImage: systemImage)
            if ax {
                // AX (§0): the value goes under the title; both wrap, never letter by letter.
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    if let value { valueText(value) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                titleText
                Spacer(minLength: 8)
                if let value { valueText(value).lineLimit(1) }
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.raftTextDisabled)
                    .padding(.leading, value == nil || ax ? 0 : -8)
                    .frame(minHeight: ax ? 26 : nil)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, ax ? 12 : 0)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(verbatim: title)
            .raftFont(.rowTitleMedium)
            .foregroundStyle(Color.raftTextPrimary)
            .padding(.vertical, 4)
    }

    private func valueText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(valueMono ? .custom(RaftFont.mono, size: 15, relativeTo: .subheadline) : RaftFont.callout.font)
            .foregroundStyle(Color.raftTextTertiary)
    }
}

/// A settings row's leading icon (大字号补充 B.2): 20 scaled with the text, at most 28, in a box
/// 4 wider (24 at the default size); at AX sizes it tops the title's first line.
struct SettingsRowIcon: View {
    let systemImage: String
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 20
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let side = min(icon, 28)
        Image(systemName: systemImage)
            // 17pt draws the 20pt symbol of the spec at the default size.
            .font(.system(size: side * 17 / 20, weight: .regular))
            .foregroundStyle(Color.raftTextSecondary)
            .frame(width: side + 4, height: typeSize.isAccessibilitySize ? side + 6 : nil)
            .padding(.top, typeSize.isAccessibilitySize ? 2 : 0)
            .accessibilityHidden(true)
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
