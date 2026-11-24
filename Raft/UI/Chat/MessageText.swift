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
}

/// Draws chip backgrounds behind runs carrying `ChipAttribute`, then the text.
struct ChipTextRenderer: TextRenderer {
    var dark: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if let chip = run[ChipAttribute.self] {
                    let bounds = run.typographicBounds.rect.insetBy(dx: 0, dy: -1)
                    let path = Path(roundedRect: bounds, cornerRadius: 4, style: .continuous)
                    context.fill(path, with: .color(fill(chip.kind)))
                    if chip.kind != .code {
                        context.stroke(Path(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 3.5, style: .continuous), with: .color(.raftInk), lineWidth: 1.5)
                        if dark {
                            context.stroke(Path(roundedRect: bounds.insetBy(dx: -0.75, dy: -0.75), cornerRadius: 4.75, style: .continuous), with: .color(Color(hex: 0xFAFAF7, alpha: 0.35)), lineWidth: 1.5)
                        }
                    }
                }
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

    private var thin: String { "\u{2009}" }

    var text: Text {
        let parsed = (try? AttributedString(
            markdown: content,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(content)
        var result = Text(verbatim: "")
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                result = result + Text(verbatim: thin + piece + thin)
                    .font(.custom(RaftFont.mono, size: font.size * 13 / 16, relativeTo: font.relativeTo))
                    .foregroundStyle(color)
                    .customAttribute(ChipAttribute(kind: .code))
                continue
            }
            let strong = intent.contains(.stronglyEmphasized)
            if let link = run.link {
                var value = AttributedString(piece)
                value.link = link
                value.underlineStyle = .single
                result = result + Text(value).font(.custom(strong ? RaftFont.bold : RaftFont.medium, size: font.size, relativeTo: font.relativeTo)).foregroundStyle(color)
                continue
            }
            result = result + tokens(piece, strong: strong)
        }
        return result
    }

    private func base(_ text: String, strong: Bool) -> Text {
        Text(verbatim: text)
            .font(.custom(strong ? RaftFont.bold : font.name, size: font.size, relativeTo: font.relativeTo))
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
        let chipSize = font.size * 0.92
        if sigil == "@" {
            let mention = mentionNames[word.lowercased()]
            let isMe = mention.map { $0.id == currentUserId } ?? false
            if isMe {
                return Text(verbatim: thin + "@" + L10n.t("ios_mention_you", "you") + thin)
                    .font(.custom(RaftFont.bold, size: chipSize, relativeTo: font.relativeTo))
                    .foregroundStyle(Color.raftInk)
                    .customAttribute(ChipAttribute(kind: .me))
            }
            guard mention != nil || word.lowercased() == "all" || word.lowercased() == "here" else { return nil }
            return Text(verbatim: "@" + word)
                .font(.custom(RaftFont.bold, size: font.size, relativeTo: font.relativeTo))
                .foregroundStyle(color)
        }
        if word.allSatisfy(\.isNumber) {
            return Text(verbatim: thin + "#" + word + thin)
                .font(.custom(RaftFont.monoBold, size: font.size * 13 / 16, relativeTo: font.relativeTo))
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
        return from(content).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
