import SwiftUI

/// Marks a run of message text drawn on a chip (§2.4 / §2.5).
struct ChipAttribute: TextAttribute {
    enum Kind: Hashable {
        /// `@you`: yellow, ink ring.
        case me
        /// `#channel`: pink, ink ring.
        case channel
        /// `#482`: stone, ink ring.
        case reference
        /// Inline code: fill only.
        case code
    }

    var kind: Kind
    /// One chip; a chip's text can be split into several runs (a font fallback for the thin
    /// spaces), which share one background.
    var id = UUID()
}

/// Draws chip backgrounds behind runs carrying `ChipAttribute`, then the text.
struct ChipTextRenderer: TextRenderer {
    var dark: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            // Union of each chip's runs on this line, in order of appearance.
            var chips: [(chip: ChipAttribute, rect: CGRect)] = []
            for run in line {
                guard let chip = run[ChipAttribute.self] else { continue }
                let rect = run.typographicBounds.rect
                if let index = chips.firstIndex(where: { $0.chip.id == chip.id }) {
                    chips[index].rect = chips[index].rect.union(rect)
                } else {
                    chips.append((chip, rect))
                }
            }
            for (chip, rect) in chips where rect.width >= 8 {
                // A sliver (< 8pt) is just the padding space left behind when the chip wraps.
                let bounds = rect.insetBy(dx: 0, dy: -1)
                let path = Path(roundedRect: bounds, cornerRadius: 4, style: .continuous)
                context.fill(path, with: .color(fill(chip.kind)))
                if chip.kind != .code {
                    context.stroke(Path(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 3.5, style: .continuous), with: .color(.raftInk), lineWidth: 1.5)
                    if dark {
                        context.stroke(Path(roundedRect: bounds.insetBy(dx: -0.75, dy: -0.75), cornerRadius: 4.75, style: .continuous), with: .color(Color(hex: 0xFAFAF7, alpha: 0.35)), lineWidth: 1.5)
                    }
                }
            }
            for run in line {
                context.draw(run)
            }
        }
    }

    private func fill(_ kind: ChipAttribute.Kind) -> Color {
        switch kind {
        case .me: .raftYellow
        case .channel: .raftChannelChip
        case .reference: .raftRefChip
        case .code: dark ? Color(hex: 0x32322F) : Color(hex: 0xF3F3F3)
        }
    }
}

/// Message text: inline Markdown (bold, code, links), mentions (bold; `@you` chip) and channel
/// chips. Space Grotesk has no italic: emphasis renders upright.
struct MessageText: View {
    let content: String
    var mentions: [MessageMention] = []
    var currentUserId: String?
    var channelNames: Set<String> = []
    var font: RaftFont = .body
    var color: Color = .raftTextPrimary
    var lineLimit: Int?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MessageTextBuilder(content: content, mentions: mentions, currentUserId: currentUserId, channelNames: channelNames, font: font, color: color)
            .text
            .lineSpacing(font.lineSpacing)
            .lineLimit(lineLimit)
            .textRenderer(ChipTextRenderer(dark: scheme == .dark))
            .tint(color)
    }
}

struct MessageTextBuilder {
    let content: String
    var mentions: [MessageMention]
    var currentUserId: String?
    var channelNames: Set<String>
    var font: RaftFont
    var color: Color
    /// False for one-line previews (Home Unread cards, Activity rows): code, `#482` refs,
    /// channels and `@you` render as plain text there; pills only appear in the chat body.
    var pills: Bool = true

    /// Mono pills (code, `#482`): 13pt next to 17pt body text.
    private var monoSize: CGFloat { font.size * 13 / 17 }
    /// Grotesk pills (`@you`, `#channel`): 15pt next to 17pt body text.
    private var chipSize: CGFloat { font.size * 15 / 17 }

    /// Chip padding. Narrow NO-BREAK space: a breakable thin space (U+2009) let a wrapped
    /// chip leave its leading pad on the previous line, drawn as an empty ring.
    private var thin: String { "\u{202F}" }

    var text: Text {
        // Agents often end a message with blank lines; they would show as empty space.
        let content = self.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = (try? AttributedString(
            markdown: content,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(content)
        var result = Text(verbatim: "")
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code), pills {
                result = result + Text(verbatim: thin + piece + thin)
                    .font(.custom(RaftFont.mono, size: monoSize, relativeTo: font.relativeTo))
                    .foregroundStyle(color)
                    .customAttribute(ChipAttribute(kind: .code))
                continue
            }
            let strong = intent.contains(.stronglyEmphasized)
            if let link = run.link {
                var value = AttributedString(piece)
                value.link = link
                value.underlineStyle = .single
                result = result + Text(value).font(font.weighted(strong ? .bold : .medium, groteskName: strong ? RaftFont.bold : RaftFont.medium)).foregroundStyle(color)
                continue
            }
            result = result + tokens(piece, strong: strong)
        }
        return result
    }

    private func base(_ text: String, strong: Bool) -> Text {
        Text(verbatim: text)
            .font(strong ? font.weighted(.bold, groteskName: RaftFont.bold) : font.font)
            .tracking(font.tracking)
            .foregroundStyle(color)
    }

    /// Splits `@mentions` and `#channels` out of plain text.
    private func tokens(_ piece: String, strong: Bool) -> Text {
        var result = Text(verbatim: "")
        var buffer = ""
        var index = piece.startIndex
        let mentionNames = Dictionary(mentions.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        while index < piece.endIndex {
            let character = piece[index]
            let atBoundary = index == piece.startIndex || piece[piece.index(before: index)].isWhitespace || "([{".contains(piece[piece.index(before: index)])
            if (character == "@" || character == "#"), atBoundary {
                var end = piece.index(after: index)
                while end < piece.endIndex, piece[end].isLetter || piece[end].isNumber || "-_.".contains(piece[end]) { end = piece.index(after: end) }
                // A trailing dot ends the sentence, not the name.
                while end > piece.index(after: index), piece[piece.index(before: end)] == "." { end = piece.index(before: end) }
                let word = String(piece[piece.index(after: index)..<end])
                if !word.isEmpty, let chip = classify(character, word, mentionNames) {
                    if !buffer.isEmpty { result = result + base(buffer, strong: strong); buffer = "" }
                    result = result + chip
                    index = end
                    continue
                }
            }
            buffer.append(character)
            index = piece.index(after: index)
        }
        if !buffer.isEmpty { result = result + base(buffer, strong: strong) }
        return result
    }

    private func classify(_ sigil: Character, _ word: String, _ mentionNames: [String: MessageMention]) -> Text? {
        if sigil == "@" {
            let mention = mentionNames[word.lowercased()]
            let isMe = mention.map { $0.id == currentUserId } ?? false
            if isMe, pills {
                return Text(verbatim: thin + "@" + L10n.t("ios_mention_you", "you") + thin)
                    .font(.custom(RaftFont.bold, size: chipSize, relativeTo: font.relativeTo))
                    .foregroundStyle(Color.raftInk)
                    .customAttribute(ChipAttribute(kind: .me))
            }
            guard mention != nil || word.lowercased() == "all" || word.lowercased() == "here" else { return nil }
            return Text(verbatim: "@" + word)
                .font(font.weighted(.bold, groteskName: RaftFont.bold))
                .foregroundStyle(color)
        }
        guard pills else { return nil }
        if word.allSatisfy(\.isNumber) {
            return Text(verbatim: thin + "#" + word + thin)
                .font(.custom(RaftFont.monoBold, size: monoSize, relativeTo: font.relativeTo))
                .foregroundStyle(Color.raftInk)
                .customAttribute(ChipAttribute(kind: .reference))
        }
        guard channelNames.contains(word.lowercased()) else { return nil }
        return Text(verbatim: thin + "#" + word + thin)
            .font(.custom(RaftFont.semibold, size: chipSize, relativeTo: font.relativeTo))
            .foregroundStyle(Color.raftInk)
            .customAttribute(ChipAttribute(kind: .channel))
    }
}

enum PlainText {
    /// Markdown stripped to its text (previews, VoiceOver, Copy text).
    static func from(_ content: String) -> String {
        let parsed = try? AttributedString(
            markdown: content,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )
        return parsed.map { String($0.characters) } ?? content
    }

    /// One line for list previews.
    static func preview(_ content: String?) -> String {
        guard let content else { return "" }
        // Markers CommonMark leaves as text (bold next to CJK punctuation, a server-cut "**…").
        var text = from(content)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        if text.hasSuffix("*…") { text = String(text.dropLast(2)) + "…" }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
