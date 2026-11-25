import SwiftUI

// MARK: Timeline (§2.6)

/// One line of a conversation: a date line, a message (or this device's pending send) with its
/// grouping, or a system notice.
struct ChatEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case date(String)
        case message(Message, continuation: Bool)
        case pending(PendingSend, continuation: Bool)
        case system(Message)
    }

    let id: String
    let kind: Kind
}

enum ChatTimeline {
    /// Date lines between days; a message from the same author within 5 minutes of the previous
    /// one continues it (no avatar, no header).
    static func entries(messages: [Message], pending: [PendingSend], currentUserId: String, calendar: Calendar = .current) -> [ChatEntry] {
        var result: [ChatEntry] = []
        var previous: (sender: String, date: Date)?
        var lastDay: Date?

        func dateLine(for date: Date) {
            let day = calendar.startOfDay(for: date)
            guard lastDay != day else { return }
            lastDay = day
            previous = nil
            let key = ISO8601DateFormatter.string(from: day, timeZone: calendar.timeZone, formatOptions: [.withFullDate])
            result.append(ChatEntry(id: "d:\(key)", kind: .date(RaftFormat.day(date, calendar: calendar))))
        }

        func continues(_ sender: String, _ date: Date) -> Bool {
            guard let previous else { return false }
            return previous.sender == sender && date.timeIntervalSince(previous.date) < 300 && date >= previous.date
        }

        for message in messages {
            let date = message.createdDate ?? previous?.date ?? Date()
            dateLine(for: date)
            if message.senderType == "system" || message.messageType == "system" {
                result.append(ChatEntry(id: "m:\(message.id)", kind: .system(message)))
                previous = nil
                continue
            }
            let sender = "\(message.senderType):\(message.senderId)"
            let continuation = continues(sender, date) && !message.isDeleted
            result.append(ChatEntry(id: "m:\(message.id)", kind: .message(message, continuation: continuation)))
            previous = (sender, date)
        }
        let me = "user:\(currentUserId)"
        for item in pending {
            dateLine(for: item.createdAt)
            let continuation = continues(me, item.createdAt)
            result.append(ChatEntry(id: "p:\(item.randomId)", kind: .pending(item, continuation: continuation)))
            previous = (me, item.createdAt)
        }
        return result
    }
}

// MARK: Row content

/// What a message row shows, from a server message or a pending send.
struct MessageRowModel: Identifiable {
    enum State: Equatable {
        case sent
        case pending
        case failed(String)
        case deleted
    }

    var id: String
    var persona: Persona
    var isMine: Bool
    var date: Date?
    var text: String
    var mentions: [MessageMention]
    var attachments: [MessageAttachment] = []
    var pendingAttachmentNames: [String] = []
    var reactions: [MessageReaction] = []
    var thread: ThreadInfo?
    var state: State = .sent
    var message: Message?
    var pending: PendingSend?

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// The text Copy text puts on the pasteboard.
    var plainText: String { PlainText.from(text) }
}

/// What rows need from the conversation around them.
struct ChatContext {
    var currentUserId: String
    var channelNames: Set<String>
    var directory: DirectoryStore
    var attachments: AttachmentStore
}

/// The taps a row hands back to its screen.
struct MessageRowActions {
    var toggleReaction: (String) -> Void = { _ in }
    var addReaction: () -> Void = {}
    var openThread: () -> Void = {}
    var retry: () -> Void = {}
    var openAttachment: (MessageAttachment) -> Void = { _ in }
    var longPress: (CGRect) -> Void = { _ in }
    var copyText: () -> Void = {}
    var copyLink: () -> Void = {}
    var replyInThread: () -> Void = {}
    /// Save / Remove from Saved (12b); nil where it is not offered.
    var toggleSaved: (() -> Void)?
}

/// Not observed: the row's last known frame, read when it is long-pressed.
final class FrameBox {
    var frame: CGRect = .zero
}

// MARK: Message row (§2.6)

struct MessageRowView: View {
    let row: MessageRowModel
    let context: ChatContext
    var continuation = false
    /// The lifted copy in the actions overlay drops the add-reaction chip.
    var showsAddReaction = true
    var highlighted = false
    var interactive = true
    var horizontalPadding: CGFloat = 16
    var actions = MessageRowActions()

    @State private var frameBox = FrameBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SavedStore.self) private var savedStore: SavedStore?

    /// 12c: a sent message this person saved.
    private var isSaved: Bool { row.state == .sent && savedStore?.isSaved(row.id) == true }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if continuation {
                // The mark of a continued message sits in the avatar column (12c).
                ZStack(alignment: .topTrailing) {
                    Color.clear.frame(width: AvatarSize.md.side, height: 1)
                    if isSaved { SavedMark().padding(.top, 1).transition(SavedMark.transition) }
                }
                .frame(width: AvatarSize.md.side, alignment: .topTrailing)
                .animation(.spring(duration: 0.25, bounce: 0.3), value: isSaved)
            } else {
                AvatarView(persona: row.persona, size: .md, showsPresence: true, ringColor: .raftCanvas)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !continuation { header }
                bodyText
                if !row.attachments.isEmpty {
                    attachmentList.padding(.top, 8)
                } else if !row.pendingAttachmentNames.isEmpty {
                    pendingAttachments.padding(.top, 6)
                }
                if !row.reactions.isEmpty {
                    reactionRow.padding(.top, 6)
                }
                if let thread = row.thread, thread.replyCount > 0 {
                    ThreadPreviewBox(thread: thread, context: context, open: actions.openThread)
                        .padding(.top, 8)
                }
                if row.isFailed {
                    FailedLine(retry: actions.retry)
                        .padding(.top, 6)
                        .transition(.opacity)
                } else if row.state == .pending {
                    SendingLine()
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, horizontalPadding)
        .background {
            // The located message (29c): full width, 8pt past the row above and below; on at
            // once, faded out over 0.8s (gone at once with Reduce Motion). Ease-in: an ease-out
            // fade is all but gone after 0.4s, so the flash read as ~1.6s instead of 2.0s.
            Rectangle()
                .fill(Color.raftYellow.opacity(0.22))
                .padding(.vertical, -8)
                .opacity(highlighted ? 1 : 0)
                .animation(highlighted || reduceMotion ? nil : .easeIn(duration: 0.8), value: highlighted)
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            frameBox.frame = frame
        }
        .onTapGesture {
            if row.isFailed { actions.retry() }
        }
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 12) {
            guard interactive else { return }
            actions.longPress(frameBox.frame)
        }
        #if DEBUG
        .task {
            // Preview gallery 12b: Ruby's message in the long-press menu.
            guard PreviewGallery.screen == "12b", interactive, row.id == "m3" else { return }
            try? await Task.sleep(for: .milliseconds(700))
            actions.longPress(frameBox.frame)
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(L10n.t("thread_action_reply_in_thread", "Reply in thread"))) { actions.replyInThread() }
        .accessibilityActions {
            if let toggle = actions.toggleSaved {
                Button(SavedStore.actionTitle(saved: isSaved), action: toggle)
            }
        }
        .accessibilityAction(named: Text(L10n.t("thread_action_add_reaction", "Add reaction"))) { actions.addReaction() }
        .accessibilityAction(named: Text(L10n.t("file_preview_action_copy_text", "Copy text"))) { actions.copyText() }
        .accessibilityAction(named: Text(L10n.t("thread_action_copy_link", "Copy link"))) { actions.copyLink() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: row.persona.name)
                .raftFont(.author)
                .foregroundStyle(Color.raftTextPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if row.isMine { YouSticker() }
            if row.persona.kind == .agent, let runtime = row.persona.runtime {
                Text(verbatim: runtime)
                    .raftFont(.caption)
                    .foregroundStyle(Color.raftTextTertiary)
                    .lineLimit(1)
            }
            if let date = row.date {
                Text(verbatim: RaftFormat.clock(date))
                    .raftFont(.monoCaption)
                    .foregroundStyle(Color.raftTextTertiary)
                    .fixedSize()
            }
            if isSaved {
                SavedMark()
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .transition(SavedMark.transition)
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: isSaved)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yHeader))
    }

    private var a11yHeader: String {
        var parts = [row.persona.name + (row.isMine ? " " + L10n.t("member_label_you_suffix", "(you)") : "")]
        if row.persona.kind == .agent {
            parts.append(L10n.t("member_label_agent", "Agent"))
            if let runtime = row.persona.runtime { parts.append(runtime) }
        }
        if let date = row.date { parts.append(RaftFormat.clock(date)) }
        if isSaved { parts.append(L10n.t("thread_label_saved", "Saved").lowercased()) }
        return parts.joined(separator: ", ")
    }

    // MARK: Body

    @ViewBuilder private var bodyText: some View {
        switch row.state {
        case .deleted:
            Text(L10n.t("ios_message_deleted", "This message was deleted."))
                .raftFont(.body)
                .foregroundStyle(Color.raftTextTertiary)
        default:
            if !row.text.isEmpty {
                MessageText(
                    content: row.text,
                    mentions: row.mentions,
                    currentUserId: context.currentUserId,
                    channelNames: context.channelNames,
                    color: row.state == .sent ? .raftTextPrimary : .raftTextSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.15), value: row.state)
                .accessibilityLabel(Text(verbatim: a11yBody))
                .accessibilityHint(row.isFailed ? Text(L10n.t("ios_retry_hint", "Double-tap to retry")) : Text(verbatim: ""))
            }
        }
    }

    private var a11yBody: String {
        var parts = [PlainText.from(row.text).trimmingCharacters(in: .whitespacesAndNewlines)]
        if row.attachments.count == 1 {
            parts.append(L10n.t("ios_attachment_one_a11y", "1 attachment"))
        } else if row.attachments.count > 1 {
            parts.append(L10n.f("ios_attachments_count_a11y", "%1$d attachments", row.attachments.count))
        }
        // A continued message has no header to say it is saved.
        if continuation, isSaved { parts.append(L10n.t("thread_label_saved", "Saved")) }
        if row.isFailed { parts.append(L10n.t("ios_not_sent", "Not sent")) }
        if row.state == .pending { parts.append(L10n.t("ios_message_sending", "Sending…")) }
        // One period between parts, not two when the text already ends a sentence.
        return parts.filter { !$0.isEmpty }.reduce("") { result, part in
            guard !result.isEmpty else { return part }
            return result + (".!?…".contains(result.last!) ? " " : ". ") + part
        }
    }

    // MARK: Attachments (§3-13)

    private var attachmentList: some View {
        let images = row.attachments.filter(\.isImage)
        return VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                MessageImageGroup(
                    images: images,
                    sender: row.persona,
                    date: row.date,
                    store: context.attachments,
                    fallbackOpen: actions.openAttachment,
                    interactive: interactive
                )
            }
            ForEach(row.attachments.filter { !$0.isImage }) { attachment in
                FileCardView(attachment: attachment) {
                    actions.openAttachment(attachment)
                }
            }
        }
    }

    private var pendingAttachments: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(row.pendingAttachmentNames, id: \.self) { name in
                Label {
                    Text(verbatim: name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: "paperclip")
                }
                .raftFont(.footnote)
                .foregroundStyle(Color.raftTextSecondary)
            }
        }
    }

    // MARK: Reactions (§2.7)

    private var reactionRow: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(row.reactions, id: \.emoji) { reaction in
                ReactionChip(reaction: reaction, mine: reaction.reactorIds.contains(context.currentUserId)) {
                    actions.toggleReaction(reaction.emoji)
                }
            }
            if showsAddReaction && row.state == .sent {
                AddReactionChip(action: actions.addReaction)
            }
        }
    }
}

// MARK: Reaction chips

struct ReactionChip: View {
    let reaction: MessageReaction
    let mine: Bool
    let action: () -> Void
    @State private var bounce = 0

    var body: some View {
        Button {
            bounce += 1
            action()
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: reaction.emoji).font(.system(size: 14))
                Text(verbatim: String(reaction.count))
                    .font(.custom(mine ? RaftFont.monoBold : RaftFont.mono, size: 12, relativeTo: .caption))
                    .foregroundStyle(mine ? Color.raftMineCount : Color.raftTextSecondary)
                    .contentTransition(.numericText(value: Double(reaction.count)))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(mine ? Color.raftMineReactionFill : Color.raftReactionFill, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(mine ? Color.raftYellow : Color.raftReactionRing, lineWidth: 0.5))
            .contentShape(Rectangle().inset(by: -9))
        }
        .buttonStyle(ChipPressStyle())
        .sensoryFeedback(.selection, trigger: bounce)
        .contextMenu {
            ForEach(reaction.reactorNames, id: \.self) { name in
                Text(verbatim: name)
            }
        }
        .accessibilityLabel(Text(verbatim: "\(reaction.emoji) \(reaction.count)"))
        .accessibilityValue(mine ? Text(L10n.t("ios_reaction_including_you", "including you")) : Text(verbatim: ""))
        .accessibilityAddTraits(mine ? .isSelected : [])
    }
}

struct AddReactionChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 13))
                .foregroundStyle(Color.raftTextSecondary)
                .padding(.horizontal, 6)
                .frame(minWidth: 26, minHeight: 26)
                .background(Color.raftReactionFill, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.raftReactionRing, lineWidth: 0.5))
                .contentShape(Rectangle().inset(by: -9))
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityLabel(Text(L10n.t("thread_message_a11y_add_reaction", "Add reaction")))
    }
}

struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: Thread preview (§2.7)

struct ThreadPreviewBox: View {
    let thread: ThreadInfo
    let context: ChatContext
    let open: () -> Void

    private var countText: String {
        thread.replyCount == 1
            ? L10n.t("thread_inline_reply_count_one", "1 reply")
            : L10n.f("thread_inline_reply_count_many", "%1$d replies", thread.replyCount)
    }

    private var replies: [ThreadReplyPreview] { Array(thread.latestReplies.suffix(2)) }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: countText)
                    .raftFont(.footnoteStrong)
                    .foregroundStyle(Color.raftTextSecondary)
                    .padding(.bottom, replies.isEmpty ? 2 : 4)
                ForEach(replies) { reply in
                    HStack(spacing: 6) {
                        AvatarView(persona: context.directory.persona(type: reply.senderType, id: reply.senderId, name: reply.senderName, avatarURL: reply.senderAvatarUrl), size: .xs)
                        Text(verbatim: context.directory.persona(type: reply.senderType, id: reply.senderId, name: reply.senderName).name)
                            .font(.custom(RaftFont.bold, size: 13, relativeTo: .footnote))
                            .foregroundStyle(Color.raftTextPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(verbatim: PlainText.preview(reply.preview))
                            .raftFont(.footnote)
                            .foregroundStyle(Color.raftTextSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let date = RaftDate.parse(reply.createdAt) {
                            Text(verbatim: RaftFormat.clock(date))
                                .raftFont(.monoCaption)
                                .foregroundStyle(Color.raftTextTertiary)
                                .fixedSize()
                        }
                    }
                    .frame(minHeight: 24)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 6, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(InsetCardStyle(radius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yLabel))
        .accessibilityHint(Text(L10n.t("thread_message_a11y_open_thread", "Open thread")))
        .accessibilityAddTraits(.isButton)
    }

    private var a11yLabel: String {
        guard let last = replies.last else { return countText }
        let name = context.directory.persona(type: last.senderType, id: last.senderId, name: last.senderName).name
        return L10n.f("ios_thread_preview_a11y", "%1$@, latest from %2$@: %3$@", countText, name, PlainText.preview(last.preview))
    }
}

/// The solid inset card (thread preview, file card): pressed fill darkens 4%.
struct InsetCardStyle: ButtonStyle {
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .background(Color.raftInsetCard, in: shape)
            .overlay {
                if configuration.isPressed { shape.fill(Color.raftInk.opacity(0.04)) }
            }
            .overlay(shape.strokeBorder(Color.raftInsetRing, lineWidth: 0.5))
            .contentShape(shape)
    }
}

// MARK: Attachments (§3-13)

struct FileCardView: View {
    let attachment: MessageAttachment
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                FileTypeTile(filename: attachment.filename, mimeType: attachment.mimeType)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: attachment.filename)
                        .raftFont(.chipLabel)
                        .foregroundStyle(Color.raftTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: "\(RaftFormat.bytes(attachment.sizeBytes)) · \(FileTypeTile.label(filename: attachment.filename, mimeType: attachment.mimeType))")
                        .raftFont(.monoCaption)
                        .foregroundStyle(Color.raftTextTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.raftTextSecondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: 300, alignment: .leading)
        }
        .buttonStyle(InsetCardStyle(radius: 14))
        .frame(maxWidth: 300, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(attachment.filename), \(RaftFormat.bytes(attachment.sizeBytes))"))
        .accessibilityAddTraits(.isButton)
    }
}

struct FileTypeTile: View {
    let filename: String
    let mimeType: String
    var small = false

    static func label(filename: String, mimeType: String) -> String {
        let ext = (filename as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return String(ext.prefix(4)) }
        return String((mimeType.split(separator: "/").last ?? "FILE").prefix(4)).uppercased()
    }

    private var color: Color {
        let label = Self.label(filename: filename, mimeType: mimeType)
        if label == "PDF" { return .raftOrange }
        if ["FIG", "SKET", "PSD", "AI", "SVG", "XD"].contains(label) { return .raftLavender }
        return .raftStone
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        shape.fill(color)
            .overlay(shape.strokeBorder(Color.raftInk, lineWidth: 1.5))
            .overlay(alignment: .bottom) {
                Text(verbatim: Self.label(filename: filename, mimeType: mimeType))
                    .font(.custom(RaftFont.monoBold, size: small ? 8 : 10))
                    .foregroundStyle(Color.raftInk)
                    .padding(.bottom, small ? 3 : 4)
            }
            .frame(width: small ? 27 : 35, height: small ? 34 : 44)
            .dieCut()
            .accessibilityHidden(true)
    }
}

// MARK: Failed send (§3-15)

struct FailedLine: View {
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 14))
                Text(L10n.t("ios_not_sent_tap_to_retry", "Not sent · Tap to retry"))
                    .font(.custom(RaftFont.semibold, size: 13, relativeTo: .footnote))
                Image(systemName: "arrow.clockwise").font(.system(size: 14))
            }
            .foregroundStyle(Color.raftDanger)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("send-failed-retry")
    }
}

/// Under a message this device has sent and the server has not confirmed yet; the row turns
/// normal (or failed) in place.
struct SendingLine: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 12))
            Text(L10n.t("ios_message_sending", "Sending…"))
                .raftFont(.caption)
        }
        .foregroundStyle(Color.raftTextTertiary)
        .padding(.vertical, 2)
        .accessibilityHidden(true)
        .accessibilityIdentifier("message-sending")
    }
}

// MARK: Other rows

struct SystemMessageRow: View {
    let message: Message

    var body: some View {
        Text(verbatim: PlainText.preview(message.content))
            .raftFont(.footnote)
            .foregroundStyle(Color.raftTextTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
    }
}

/// "Ruby is typing" + three dots, under the last message (§3-10).
struct TypingRow: View {
    let personas: [Persona]

    private var fullText: String {
        guard let first = personas.first?.name else { return "" }
        switch personas.count {
        case 1:
            return L10n.t("thread_agent_typing_one", "{first} is typing…").replacingOccurrences(of: "{first}", with: first)
        case 2:
            return L10n.t("thread_agent_typing_two", "{first} and {second} are typing…")
                .replacingOccurrences(of: "{first}", with: first)
                .replacingOccurrences(of: "{second}", with: personas[1].name)
        default:
            let others = String(personas.count - 2)
            return L10n.t("thread_agent_typing_many", "{first}, {second} and {others} other agents are typing…")
                .replacingOccurrences(of: "{first}", with: first)
                .replacingOccurrences(of: "{second}", with: personas[1].name)
                .replacingOccurrences(of: "{others}", with: others)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let first = personas.first {
                AvatarView(persona: first, size: .xs)
            }
            Text(verbatim: fullText.hasSuffix("…") ? String(fullText.dropLast()) : fullText)
                .raftFont(.caption)
                .foregroundStyle(Color.raftTextTertiary)
                .lineLimit(1)
            TypingDots()
        }
        .padding(.leading, 61)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: fullText))
    }
}

/// "Loading older messages…" at the top of the stream (§3-15).
struct LoadingOlderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.raftTextSecondary)
            Text(L10n.t("thread_state_loading_older", "Loading older messages…"))
                .font(.custom(RaftFont.medium, size: 13, relativeTo: .footnote))
                .foregroundStyle(Color.raftTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Flow layout

/// Wraps its children onto lines (reaction chips).
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
