import SwiftUI

// Content stickers and avatars (§2.1–2.5). Everything here is solid: no glass in content.

// MARK: People

enum Presence: Hashable, Sendable {
    case online
    case busy
    case offline

    var color: Color {
        switch self {
        case .online: .raftLime
        case .busy: .raftYellow
        case .offline: .raftStone
        }
    }

    var label: String {
        switch self {
        case .online: L10n.t("member_label_connected", "Online")
        case .busy: L10n.t("ios_presence_busy", "Working")
        case .offline: L10n.t("member_label_offline", "Offline")
        }
    }

    /// Orchestrator activity → presence.
    init(activity: String?) {
        switch activity?.lowercased() {
        case nil, "", "offline", "stopped", "sleeping", "error", "disconnected": self = .offline
        case "working", "thinking", "busy", "running", "tool_call", "responding": self = .busy
        default: self = .online
        }
    }
}

/// Who an avatar shows: a person (initials or photo) or an agent (pixel face).
struct Persona: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case human, agent }

    var id: String
    var name: String
    var kind: Kind
    var imageURL: URL?
    var pixelKey: String?
    var presence: Presence?
    var runtime: String?

    static func human(id: String, name: String, avatarURL: String? = nil) -> Persona {
        Persona(id: id, name: name, kind: .human, imageURL: Persona.httpURL(avatarURL))
    }

    static func agent(id: String, name: String, pixelKey: String? = nil, presence: Presence? = nil, runtime: String? = nil) -> Persona {
        Persona(id: id, name: name, kind: .agent, pixelKey: pixelKey, presence: presence, runtime: runtime)
    }

    static func httpURL(_ text: String?) -> URL? {
        guard let text, text.hasPrefix("https://") || text.hasPrefix("http://") else { return nil }
        return URL(string: text)
    }

    /// Up to two initials (first and last name), uppercased.
    var initials: String {
        let words = name.split { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }.filter { !$0.isEmpty }
        let letters: [Character] = switch words.count {
        case 0: []
        case 1: [words[0].first!]
        default: [words[0].first!, words[words.count - 1].first!]
        }
        return String(letters).uppercased()
    }
}

/// Agent face backgrounds (raft-design `assets/Agents/README.md`).
enum AgentFace {
    private static let backgrounds: [String: Color] = {
        let cyan = Color.raftCyan, yellow = Color.raftYellow, pink = Color.raftPink, orange = Color.raftOrange
        let lime = Color.raftLime, lavender = Color.raftLavender, red = Color.raftRed, slate = Color.raftSlate
        return [
            "robot": cyan, "antenna": yellow, "visor": pink, "drone": cyan, "tv": orange, "led": lime, "catbot": lavender, "boxbot": red,
            "cat": yellow, "dog": cyan, "fox": cyan, "frog": lavender, "bunny": cyan, "bear": lime, "penguin": cyan, "owl": slate,
            "alien": lime, "star": yellow, "rocket": slate, "planet": lavender, "moon": slate, "ufo": lavender, "astronaut": orange, "satellite": lavender,
            "bell": slate, "terminal": pink, "bulb": lavender, "magnifier": yellow, "pencil": cyan, "plane": cyan, "clipboard": orange, "floppy": yellow,
            "onigiri": lime, "donut": cyan, "icecream": cyan, "strawberry": lavender, "pizza": cyan, "egg": pink, "cookie": orange, "cupcake": yellow,
            "crown": yellow, "diamond": cyan, "heart": pink, "sword": lavender, "shield": slate, "potion": lavender, "key": lavender, "chest": cyan,
            "sun": red, "cloud": cyan, "bolt": slate, "umbrella": cyan, "rainbow": cyan, "snowman": cyan, "raincloud": slate, "partlysunny": cyan,
            "tree": lime, "mushroom": pink, "cactus": yellow, "tulip": lime, "sunflower": cyan, "pine": lavender, "leaf": cyan, "sprout": cyan,
            "ghost": lavender, "skull": orange, "eye": lavender, "flame": orange, "pumpkin": lavender, "bat": orange, "wizard": lavender, "spider": pink,
        ]
    }()

    /// A known face key (unknown and missing keys draw the default robot).
    static func key(_ value: String?) -> String {
        guard let value, backgrounds[value] != nil else { return "robot" }
        return value
    }

    static func background(_ key: String) -> Color { backgrounds[key] ?? .raftCyan }
}

enum AvatarSize {
    case xs, sm, md, lg

    var side: CGFloat {
        switch self {
        case .xs: 19
        case .sm: 27
        case .md: 35
        case .lg: 51
        }
    }

    var initialsSize: CGFloat {
        switch self {
        case .xs: 8
        case .sm: 11
        case .md: 13
        case .lg: 18
        }
    }
}

/// A square sticker avatar (§2.2): initials or photo for people, a pixel face for agents, and
/// for agents an optional presence light cut out of `ringColor` (the background it sits on).
struct AvatarView: View {
    let persona: Persona
    var size: AvatarSize = .md
    var showsPresence = false
    var ringColor: Color = .raftCanvas
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = size.side * min(scale, 1.6)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        content(side: side)
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.raftInk, lineWidth: 1.5))
            .dieCut()
            .overlay(alignment: .bottomTrailing) {
                if showsPresence, persona.kind == .agent, let presence = persona.presence {
                    presenceLight(presence)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(side: CGFloat) -> some View {
        switch persona.kind {
        case .agent:
            let key = AgentFace.key(persona.pixelKey)
            ZStack {
                AgentFace.background(key)
                Image("Agents/\(key)")
                    .resizable()
                    .interpolation(.none)
                    .clipShape(.rect(cornerRadius: 1.5))
                    .padding(size == .xs ? 0.5 : 1.5)
            }
        case .human:
            ZStack {
                Color.raftLavender
                Text(verbatim: persona.initials)
                    .font(.custom(RaftFont.bold, size: size.initialsSize * min(scale, 1.6)))
                    .tracking(-0.02 * size.initialsSize)
                    .foregroundStyle(Color.raftInk)
                if let url = persona.imageURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .clipShape(.rect(cornerRadius: 1.5))
                    .padding(1.5)
                }
            }
        }
    }

    private func presenceLight(_ presence: Presence) -> some View {
        let small = size == .xs
        let side: CGFloat = small ? 7 : 11
        let ring: CGFloat = small ? 1 : 1.5
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(presence.color)
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.raftInk, lineWidth: small ? 1 : 1.5))
            .frame(width: side, height: side)
            .padding(ring)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(ringColor))
            .offset(x: small ? 3 : 4, y: small ? 3 : 4)
    }
}

/// A server's square avatar: ink with a yellow initial, no border (§2.2).
struct ServerAvatar: View {
    let name: String
    var side: CGFloat = 35

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.raftInk)
            .frame(width: side, height: side)
            .overlay {
                Text(verbatim: String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.custom(RaftFont.bold, size: side <= 28 ? 15 : 17))
                    .foregroundStyle(Color.raftYellow)
            }
            .dieCut()
            .accessibilityHidden(true)
    }
}

/// A channel's square tile (§2.3).
struct ChannelTile: View {
    var isPrivate = false
    var isMuted = false
    var large = false
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 27

    var body: some View {
        let size = large ? 64 : min(side, 44)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(large ? Color.raftCyan : Color.raftStone)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.raftInk, lineWidth: 1.5))
            .overlay {
                Image(systemName: isPrivate ? "lock.fill" : "number")
                    .font(.system(size: large ? 30 : (isPrivate ? 13 : 14), weight: .bold))
                    .foregroundStyle(Color.raftInk)
            }
            .frame(width: size, height: size)
            .dieCut()
            .modifier(HardShadowIf(enabled: large))
            .opacity(isMuted ? 0.5 : 1)
            .accessibilityHidden(true)
    }
}

private struct HardShadowIf: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.hardShadow(3) } else { content }
    }
}

// MARK: Stickers

/// Count, mention and thread stickers (§2.1).
struct RaftSticker: View {
    enum Kind: Hashable {
        case count(Int)
        case mention
        case thread(Int)
    }

    let kind: Kind
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        HStack(spacing: 2) {
            switch kind {
            case .count(let value):
                Text(verbatim: Self.clamp(value))
            case .mention:
                Image(systemName: "at").font(.system(size: 13, weight: .semibold))
            case .thread(let value):
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 12))
                Text(verbatim: Self.clamp(value))
            }
        }
        .font(RaftFont.monoSticker.font)
        .foregroundStyle(Color.raftInk)
        .padding(.horizontal, kind == .mention ? 0 : 4)
        .frame(minWidth: height, minHeight: height, maxHeight: height)
        .background(kind == .mention ? Color.raftYellow : Color.raftPink, in: shape)
        .overlay(shape.strokeBorder(Color.raftInk, lineWidth: 1.5))
        .dieCut()
        .fixedSize()
        .accessibilityHidden(true)
    }

    static func clamp(_ value: Int) -> String { value > 99 ? "99+" : String(value) }
}

/// "You" after the author of one's own messages (§2.4).
struct YouSticker: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Text(L10n.t("activity_list_self_sender", "You"))
            .raftFont(.monoYou)
            .foregroundStyle(Color.raftInk)
            .padding(EdgeInsets(top: 2, leading: 4, bottom: 1, trailing: 4))
            .background(Color.raftYellow, in: shape)
            .overlay(shape.strokeBorder(Color.raftInk, lineWidth: 1.5))
            .dieCut()
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A gray count for muted conversations (no sticker).
struct MutedCount: View {
    let value: Int
    var body: some View {
        Text(verbatim: RaftSticker.clamp(value))
            .raftFont(.monoCaption)
            .foregroundStyle(Color.raftTextTertiary)
    }
}

/// The unread / mention / thread stickers of a row, mention first.
struct UnreadStickers: View {
    var unread: Int
    var mention: Bool
    var threadUnread: Int = 0
    var muted = false

    var body: some View {
        HStack(spacing: 4) {
            if muted && !mention {
                if unread > 0 { MutedCount(value: unread) }
            } else {
                if mention { RaftSticker(kind: .mention) }
                if unread > 0 {
                    RaftSticker(kind: .count(unread))
                } else if threadUnread > 0 {
                    RaftSticker(kind: .thread(threadUnread))
                }
            }
        }
    }
}

// MARK: Lines and headers

/// A centered label between two 1pt lines (§2.6 `DateLine`).
struct DateLine: View {
    let text: String
    var strong = false

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.raftDivider).frame(height: 1)
            Text(verbatim: text)
                .raftFont(strong ? .grotesk(RaftFont.semibold, 12, relativeTo: .caption) : .caption)
                .foregroundStyle(Color.raftTextTertiary)
                .fixedSize()
            Rectangle().fill(Color.raftDivider).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A group title over a card: title, optional count, optional trailing control (§2.13).
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var top: CGFloat = 20
    var bottom: CGFloat = 8
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: title)
                .raftFont(.footnoteStrong)
                .foregroundStyle(Color.raftTextTertiary)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(verbatim: String(count))
                    .raftFont(.monoCaption)
                    .foregroundStyle(Color.raftTextTertiary)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, top)
        .padding(.bottom, bottom)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, top: CGFloat = 20, bottom: CGFloat = 8) {
        self.init(title: title, count: count, top: top, bottom: bottom) { EmptyView() }
    }
}

/// Inline navigation title with an optional subtitle (§2.12).
struct NavTitle: View {
    let title: String
    var hashPrefix = false
    var subtitle: String?

    var body: some View {
        VStack(spacing: 0) {
            (hashPrefix ? Text(verbatim: "# ").foregroundStyle(Color.raftTextTertiary) : Text(verbatim: ""))
                .raftStyle(.navTitle)
                + Text(verbatim: title).raftStyle(.navTitle).foregroundStyle(Color.raftTextPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .raftFont(.caption)
                    .foregroundStyle(Color.raftTextTertiary)
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Typing

/// Three square dots cycling opacity (static under Reduce Motion).
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.raftTextTertiary)
                        .frame(width: 4, height: 4)
                        .opacity([1, 0.6, 0.3][(index + 3 - phase) % 3])
                }
            }
        }
        .accessibilityHidden(true)
    }
}
