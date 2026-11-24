import SwiftUI

// Design tokens from `.airbuild/specs/ui/design.md` §1 (direction A: native chrome, Raft content).

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// A dynamic color: `light` / `dark`.
    init(light: Color, dark: Color) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }

    // MARK: Brand (same in light and dark)
    static let raftInk = Color(hex: 0x141111)
    static let raftYellow = Color(hex: 0xFFD440)
    static let raftPink = Color(hex: 0xFF99C3)
    static let raftCyan = Color(hex: 0x27CCF3)
    static let raftRed = Color(hex: 0xF97264)
    static let raftLime = Color(hex: 0xA9D877)
    static let raftLavender = Color(hex: 0xBBAFE6)
    static let raftStone = Color(hex: 0xC0B9B1)
    static let raftOrange = Color(hex: 0xF8A16F)
    /// Slate gray: agent avatar backgrounds outside the palette.
    static let raftSlate = Color(hex: 0x8A9AA8)

    static let raftCyanSoft = Color(hex: 0xD7F2FE)
    static let raftRefChip = Color(hex: 0xDAD5CF)
    static let raftChannelChip = Color(hex: 0xFFD6E2)

    // MARK: Canvas and cards
    static let raftCanvas = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1B1B19))
    static let raftCanvasWarm = Color(light: Color(hex: 0xF7F5F2), dark: Color(hex: 0x1B1B19))
    static let raftCard = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x242422))
    static let raftFill = Color(light: Color(hex: 0xF3F3F3), dark: Color(hex: 0x32322F))
    static let raftSkeleton = Color(light: Color(hex: 0xE9E5E0), dark: Color(hex: 0x32322F))

    // MARK: Text
    static let raftTextPrimary = Color(light: .raftInk, dark: Color(hex: 0xE5E5E2))
    static let raftTextSecondary = Color(light: Color(hex: 0x141111, alpha: 0.68), dark: Color(hex: 0xC4C4C1))
    static let raftTextTertiary = Color(light: Color(hex: 0x141111, alpha: 0.62), dark: Color(hex: 0x9E9E9B))
    static let raftTextDisabled = Color(light: Color(hex: 0x141111, alpha: 0.30), dark: Color(hex: 0x636360))
    static let raftDanger = Color(light: Color(hex: 0xC23A2B), dark: Color(hex: 0xF8A49D))

    // MARK: Lines
    static let raftHairline = Color(light: Color(hex: 0x141111, alpha: 0.14), dark: Color(hex: 0xFAFAF7, alpha: 0.10))
    static let raftDivider = Color(light: Color(hex: 0x141111, alpha: 0.15), dark: Color(hex: 0xFAFAF7, alpha: 0.12))
    static let raftCardRing = Color(light: Color(hex: 0x141111, alpha: 0.08), dark: Color(hex: 0xFFFFFF, alpha: 0.08))
    static let raftDieCut = Color(light: .clear, dark: Color(hex: 0xFAFAF7, alpha: 0.35))

    // MARK: Highlight
    static let raftHighlight = Color(light: Color(hex: 0xFFF0BD), dark: Color(hex: 0xFFD440, alpha: 0.22))
    static let raftHighlightStroke = Color(light: Color(hex: 0x967300, alpha: 0.25), dark: Color(hex: 0xFFD440, alpha: 0.50))
    static let raftMineCount = Color(light: Color(hex: 0x564919), dark: Color(hex: 0xFFD440))

    static let raftErrorFieldBG = Color(light: Color(hex: 0xFFF7F6), dark: Color(hex: 0xF97264, alpha: 0.12))

    // MARK: Solid content surfaces (XIN 5144: no glass in the stream)
    static let raftReactionFill = Color(light: Color(hex: 0xF2F0EC), dark: Color(hex: 0x2A2A27))
    static let raftReactionRing = Color(light: Color(hex: 0x141111, alpha: 0.10), dark: Color(hex: 0xFFFFFF, alpha: 0.10))
    static let raftMineReactionFill = Color(light: Color(hex: 0xFFD440, alpha: 0.35), dark: Color(hex: 0xFFD440, alpha: 0.22))
    static let raftInsetCard = Color(light: Color(hex: 0xF7F5F2), dark: Color(hex: 0x242422))
    static let raftInsetRing = Color(light: Color(hex: 0x141111, alpha: 0.08), dark: Color(hex: 0xFFFFFF, alpha: 0.10))
    static let raftFieldRing = Color(light: Color(hex: 0x141111, alpha: 0.20), dark: Color(hex: 0xFFFFFF, alpha: 0.20))
    static let raftFieldFill = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x242422))
}

// MARK: Typography (§1.2)

struct RaftFont: Sendable {
    enum Family: Sendable { case grotesk, mono }

    var name: String
    var size: CGFloat
    var lineHeight: CGFloat?
    var tracking: CGFloat = 0
    var relativeTo: Font.TextStyle
    var family: Family = .grotesk

    var font: Font { Font.custom(name, size: size, relativeTo: relativeTo) }

    /// `target − natural` line height (Space Grotesk 1.276×, Space Mono 1.481×); none when negative.
    var lineSpacing: CGFloat {
        guard let lineHeight else { return 0 }
        let natural = size * (family == .grotesk ? 1.276 : 1.481)
        return max(0, lineHeight - natural)
    }

    static let regular = "SpaceGrotesk-Regular"
    static let medium = "SpaceGrotesk-Medium"
    static let semibold = "SpaceGrotesk-SemiBold"
    static let bold = "SpaceGrotesk-Bold"
    static let mono = "SpaceMono-Regular"
    static let monoBold = "SpaceMono-Bold"

    static let authTitle = RaftFont(name: bold, size: 28, lineHeight: 34, tracking: -0.56, relativeTo: .title)
    static let authTitleLeading = RaftFont(name: bold, size: 26, lineHeight: 32, tracking: -0.52, relativeTo: .title)
    static let emptyTitle = RaftFont(name: bold, size: 22, lineHeight: 28, tracking: -0.22, relativeTo: .title2)
    static let navTitle = RaftFont(name: bold, size: 17, lineHeight: 22, relativeTo: .headline)
    static let buttonLabel = RaftFont(name: bold, size: 17, relativeTo: .headline)
    static let buttonLabelSecondary = RaftFont(name: semibold, size: 17, relativeTo: .headline)
    static let buttonLabelSmall = RaftFont(name: semibold, size: 15, relativeTo: .subheadline)
    static let body = RaftFont(name: regular, size: 16, lineHeight: 24, relativeTo: .body)
    static let rowTitle = RaftFont(name: semibold, size: 16, lineHeight: 22, relativeTo: .body)
    static let rowTitleMedium = RaftFont(name: medium, size: 16, lineHeight: 22, relativeTo: .body)
    static let author = RaftFont(name: bold, size: 15, lineHeight: 20, relativeTo: .subheadline)
    static let activityTitle = RaftFont(name: medium, size: 15, lineHeight: 20, relativeTo: .subheadline)
    static let chipLabel = RaftFont(name: semibold, size: 15, lineHeight: 20, relativeTo: .subheadline)
    static let callout = RaftFont(name: regular, size: 15, lineHeight: 22, relativeTo: .subheadline)
    static let link = RaftFont(name: semibold, size: 15, relativeTo: .subheadline)
    static let preview = RaftFont(name: regular, size: 14, lineHeight: 20, relativeTo: .subheadline)
    static let errorText = RaftFont(name: semibold, size: 14, lineHeight: 20, relativeTo: .subheadline)
    static let segment = RaftFont(name: semibold, size: 14, relativeTo: .subheadline)
    static let footnoteStrong = RaftFont(name: semibold, size: 13, lineHeight: 18, relativeTo: .footnote)
    static let footnote = RaftFont(name: regular, size: 13, lineHeight: 18, relativeTo: .footnote)
    static let footnoteMedium = RaftFont(name: medium, size: 13, lineHeight: 18, relativeTo: .footnote)
    static let caption = RaftFont(name: medium, size: 12, lineHeight: 16, relativeTo: .caption)
    static let monoCaption = RaftFont(name: mono, size: 12, relativeTo: .caption, family: .mono)
    static let monoSticker = RaftFont(name: monoBold, size: 12, relativeTo: .caption, family: .mono)
    static let monoSmall = RaftFont(name: mono, size: 11, relativeTo: .caption2, family: .mono)
    static let monoYou = RaftFont(name: monoBold, size: 11, relativeTo: .caption2, family: .mono)
    static let monoCode = RaftFont(name: mono, size: 13, relativeTo: .footnote, family: .mono)
    static let monoRef = RaftFont(name: monoBold, size: 13, relativeTo: .footnote, family: .mono)
    static let monoField = RaftFont(name: mono, size: 17, tracking: 0.68, relativeTo: .body, family: .mono)
    static let monoDigit = RaftFont(name: monoBold, size: 26, relativeTo: .title, family: .mono)

    static func grotesk(_ name: String, _ size: CGFloat, relativeTo: Font.TextStyle = .body) -> RaftFont {
        RaftFont(name: name, size: size, relativeTo: relativeTo)
    }
}

extension View {
    /// Font, tracking and line spacing of a Raft text token.
    func raftFont(_ token: RaftFont) -> some View {
        font(token.font)
            .tracking(token.tracking)
            .lineSpacing(token.lineSpacing)
    }
}

extension Text {
    func raftStyle(_ token: RaftFont) -> Text {
        font(token.font).tracking(token.tracking)
    }
}

// MARK: Shapes and shadows (§1.3, §1.5)

extension Shape where Self == RoundedRectangle {
    static func raftRect(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

enum RaftShadow {
    case card
    case unreadCard
    case chip
}

private struct RaftShadowModifier<S: InsettableShape>: ViewModifier {
    let kind: RaftShadow
    let shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let (ring, color, radius, y): (Double, Double, CGFloat, CGFloat) = switch kind {
        case .card: (0.08, 0.04, 5, 2)
        case .unreadCard: (0.10, 0.06, 7, 4)
        case .chip: (0.10, 0.05, 4, 2)
        }
        content
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.08) : Color.raftInk.opacity(ring), lineWidth: 0.5))
            .shadow(color: dark ? .clear : Color.raftInk.opacity(color), radius: radius, y: y)
    }
}

extension View {
    /// Solid `raftCard` surface with its ring and light-mode shadow.
    func raftCardSurface(_ kind: RaftShadow = .card, radius: CGFloat = 16, fill: Color = .raftCard) -> some View {
        background(fill, in: .raftRect(radius))
            .modifier(RaftShadowModifier(kind: kind, shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    /// The hard ink offset shadow of illustration stickers.
    func hardShadow(_ offset: CGFloat = 3) -> some View {
        shadow(color: .raftInk, radius: 0, x: offset, y: offset)
    }

    /// Floating glass (only for the layer above content: composer, banners, menus), solid when
    /// Reduce Transparency is on.
    func raftGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(RaftGlassModifier(shape: shape, interactive: interactive))
    }

    /// The 1.5pt die-cut ring stickers wear in dark mode (§1.6).
    func dieCut(radius: CGFloat = 4) -> some View {
        background(RoundedRectangle(cornerRadius: radius + 1.5, style: .continuous).fill(Color.raftDieCut).padding(-1.5))
    }
}

private struct RaftGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(scheme == .dark ? Color(hex: 0x2C2C29) : Color.raftCard, in: shape)
                .overlay(shape.stroke(scheme == .dark ? Color.white.opacity(0.12) : Color.raftInk.opacity(0.12), lineWidth: 0.5))
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}

// MARK: Fonts

enum RaftFonts {
    /// The six faces registered through `UIAppFonts`; true when all resolve.
    static var allRegistered: Bool {
        [RaftFont.regular, RaftFont.medium, RaftFont.semibold, RaftFont.bold, RaftFont.mono, RaftFont.monoBold]
            .allSatisfy { UIFont(name: $0, size: 12) != nil }
    }

    /// System controls that cannot take a SwiftUI font (segmented control labels).
    @MainActor static func applyAppearance() {
        if let segment = UIFont(name: RaftFont.semibold, size: 14) {
            let scaled = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: segment)
            UISegmentedControl.appearance().setTitleTextAttributes([.font: scaled], for: .normal)
        }
        // The Activity dot: pink (the system badge stays round, §9.9). The tab bar's own
        // appearance is left alone so it keeps the system glass.
        UITabBarItem.appearance().badgeColor = UIColor(Color.raftPink)
    }
}
