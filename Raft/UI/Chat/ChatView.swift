import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: Rows from store data

@MainActor
enum ChatRows {
    static func row(_ message: Message, directory: DirectoryStore, currentUserId: String, thread: ThreadInfo?) -> MessageRowModel {
        MessageRowModel(
            id: message.id,
            persona: directory.persona(for: message),
            isMine: message.senderType == "user" && message.senderId == currentUserId,
            date: message.createdDate,
            text: message.content,
            mentions: message.mentions,
            attachments: message.isDeleted ? [] : message.attachments,
            reactions: message.isDeleted ? [] : message.reactions,
            thread: thread,
            state: message.isDeleted ? .deleted : .sent,
            message: message
        )
    }

    static func row(_ pending: PendingSend, me: Persona) -> MessageRowModel {
        let state: MessageRowModel.State = switch pending.state {
        case .sending: .pending
        case .failed(let reason): .failed(reason)
        }
        return MessageRowModel(
            id: pending.randomId,
            persona: me,
            isMine: true,
            date: pending.createdAt,
            text: pending.content,
            mentions: pending.mentions,
            pendingAttachmentNames: pending.attachmentNames,
            state: state,
            pending: pending
        )
    }
}

/// Scroll facts the stream reacts to.
struct StreamEdges: Equatable {
    var nearTop: Bool
    var atBottom: Bool
    /// The content is taller than the space it shows in (it can scroll).
    var overflows = true
}

// MARK: 09 / 10 / 11 / 12 / 13 / 14 / 15 Chat

struct ChatView: View {
    let store: ConversationStore
    let ref: ConversationRef
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var composer = ComposerModel()
    @State private var interactions = MessageInteractions()
    @FocusState private var composerFocused: Bool
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var edges = StreamEdges(nearTop: false, atBottom: true)
    @State private var holdingForOlder = false
    @State private var showsBanner = false
    @State private var showsSpinner = false
    @State private var didFocus = false
    /// VoiceOver lands on the message the conversation opened at (29c).
    @AccessibilityFocusState private var focusedEntry: String?
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var importingFiles = false
    @State private var sendTick = 0
    @State private var joinFlow = ChannelJoinFlow()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDirectMessage: Bool { store.kind == .directMessage }
    /// A task's conversation, opened from Activity: read-only, no threads or links.
    private var isTask: Bool { store.kind == .task }
    /// An unjoined channel opened from Browse (§11 26): read-only, with the Join bar.
    private var isPreview: Bool { store.kind == .channel && workspace.channelList.isPreview(store.channelId) }
    private var memberCount: Int? { workspace.channelList.memberCount(store.channelId) }

    private var context: ChatContext {
        ChatContext(
            currentUserId: store.currentUserId,
            channelNames: Set(workspace.channelList.channels.map { $0.name.lowercased() }),
            directory: workspace.directory,
            attachments: workspace.attachments
        )
    }

    private var entries: [ChatEntry] {
        ChatTimeline.entries(messages: store.messages, pending: store.pending, currentUserId: store.currentUserId)
    }

    private var isEmpty: Bool {
        store.phase == .loaded && store.messages.isEmpty && store.pending.isEmpty && !store.hasOlder
    }

    private var topic: String? {
        let text = workspace.channelList.channels.first { $0.id == store.channelId }?.description
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : PlainText.preview($0) }
    }

    private var me: Persona {
        let user = model.session.user
        return workspace.directory.persona(type: "user", id: store.currentUserId, name: user?.displayName ?? user?.name, avatarURL: user?.avatarUrl)
    }

    private var peer: Persona? {
        guard isDirectMessage, let dm = workspace.channelList.directMessages.first(where: { $0.id == store.channelId }) else { return nil }
        return workspace.directory.persona(type: dm.peerType == "agent" ? "agent" : "user", id: dm.peerId, name: dm.peerDisplayName ?? dm.peerName, avatarURL: dm.peerAvatarUrl)
    }

    /// The DM's name in the title: "XIN (you)" for a DM with yourself.
    private var peerTitle: String? {
        guard let peer else { return nil }
        let dm = workspace.channelList.directMessages.first { $0.id == store.channelId }
        return dm?.isSelf(currentUserId: store.currentUserId) == true ? L10n.withYouSuffix(peer.name) : peer.name
    }

    private var mentionCandidates: [MentionCandidate] {
        guard let query = composer.mentionQuery else { return [] }
        return workspace.directory.mentionMatches(query, excluding: store.currentUserId)
    }

    var body: some View {
        stream
            .background(Color.raftCanvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: peerTitle ?? store.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { title }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                if showsBanner {
                    StatusBanner(updatedAt: workspace.lastConnectedAt)
                        .padding(.vertical, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .safeAreaBar(edge: .bottom) { composerBar }
            .messageInteractions(interactions) { messageId, emoji in react(messageId, emoji) }
            .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { addFiles(await AttachmentImport.load(items)) }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { image in
                    if let file = AttachmentImport.load(image) { addFiles([file]) }
                }
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { addFiles(AttachmentImport.load(urls)) }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
            .sensoryFeedback(.impact(weight: .light), trigger: joinFlow.tapTick)
            .sensoryFeedback(.success, trigger: joinFlow.successTick)
            .sensoryFeedback(.error, trigger: joinFlow.errorTick)
            .task(id: isPreview) {
                if isPreview { await workspace.channelList.loadMemberCount(store.channelId) }
            }
            .animation(showsBanner ? .easeOut(duration: 0.25) : .easeIn(duration: 0.2), value: showsBanner)
            // The keyboard and the composer's collapse/expand change the bottom inset together;
            // the bottom anchor can overshoot past the last message. Re-pin when it was at the bottom.
            .onChange(of: composerFocused) {
                guard edges.atBottom else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(380))
                    // By id: `scrollTo(edge:)` is a no-op here, the position still reads as "bottom".
                    if let last = entries.last?.id {
                        withAnimation(.smooth(duration: 0.2)) { position.scrollTo(id: last, anchor: .bottom) }
                    }
                }
            }
            .task { await start() }
            .task(id: workspace.isOffline) {
                guard workspace.isOffline else {
                    showsBanner = false
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, workspace.isOffline else { return }
                showsBanner = true
            }
            .task(id: store.phase == .loading) {
                showsSpinner = false
                guard store.phase == .loading else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { showsSpinner = true }
            }
            .onAppear {
                store.isVisible = scenePhase == .active
                #if DEBUG
                if let draft = PreviewGallery.takeDraft(for: store.channelId) { composer = draft }
                #endif
            }
            .onDisappear { store.isVisible = false }
            .onChange(of: scenePhase) { _, phase in store.isVisible = phase == .active }
            .onChange(of: store.errorMessage) { _, message in
                guard let message else { return }
                model.showToast(message)
                store.errorMessage = nil
            }
            .onChange(of: mentionCandidates.count) { old, new in
                if new > 0 && old == 0 {
                    AccessibilityNotification.Announcement(L10n.f("ios_mention_suggestions", "%1$d suggestions", new)).post()
                }
            }
    }

    private func start() async {
        await store.start(focusMessageId: ref.focusMessageId)
        guard !didFocus, let focus = store.focusMessageId else {
            // Lazy rows are measured as they appear; settle on the real bottom once they are.
            if !didFocus {
                didFocus = true
                try? await Task.sleep(for: .milliseconds(150))
                position.scrollTo(edge: .bottom)
            }
            return
        }
        didFocus = true
        try? await Task.sleep(for: .milliseconds(120))
        position.scrollTo(id: "m:\(focus)", anchor: .center)
        interactions.flash("m:\(focus)")
        focusedEntry = "m:\(focus)"
    }

    // MARK: Title (§2.12, 10)

    @ViewBuilder private var title: some View {
        if isDirectMessage, let peer {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    AvatarView(persona: peer, size: .sm)
                    Text(verbatim: peerTitle ?? peer.name)
                        .raftFont(.navTitle)
                        .foregroundStyle(Color.raftTextPrimary)
                        .lineLimit(1)
                }
                if let subtitle = dmSubtitle(peer) {
                    HStack(spacing: 5) {
                        if let presence = peer.presence {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(presence.color)
                                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.raftInk, lineWidth: 1))
                                .frame(width: 8, height: 8)
                        }
                        Text(verbatim: subtitle)
                            .raftFont(.caption)
                            .foregroundStyle(Color.raftTextTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else if isTask || isDirectMessage {
            NavTitle(title: store.title, hashPrefix: !isDirectMessage, subtitle: isDirectMessage ? nil : (ref.subtitle ?? topic))
        } else {
            // A channel: the title opens Channel info (§11 27).
            Button {
                model.push(.channelInfo(store.channelId))
            } label: {
                NavTitle(title: store.title, hashPrefix: true, subtitle: channelSubtitle)
                    .contentTransition(.numericText())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "# \(store.title), " + L10n.t("ios_channel_info_title", "Channel info")))
            .accessibilityHint(Text(L10n.t("ios_channel_info_hint", "Shows channel details")))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("chat-title")
        }
    }

    /// Preview: "Preview · 18 members"; just joined here: "19 members"; else the topic.
    private var channelSubtitle: String? {
        if isPreview {
            guard let memberCount else { return L10n.t("ios_channel_preview_label", "Preview") }
            return L10n.f("ios_channel_preview_subtitle", "Preview · %1$d members", memberCount)
        }
        if joinFlow.joinedHere, let memberCount { return MemberCountText.text(memberCount) }
        return ref.subtitle ?? topic ?? memberCount.map(MemberCountText.text)
    }

    private func dmSubtitle(_ peer: Persona) -> String? {
        let parts = [peer.kind == .agent ? peer.runtime : nil, peer.presence?.label].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Stream (§2.6)

    private var stream: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                streamContent
            }
            .scrollTargetLayout()
            .padding(.bottom, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor((isEmpty || store.isLoadingOlder || store.phase != .loaded) ? .top : .bottom, for: .alignment)
        .defaultScrollAnchor((edges.atBottom || holdingForOlder) ? .bottom : .top, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        // System soft fade under the nav bar (§2.12); no custom bar background or divider.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollGeometryChange(for: StreamEdges.self) { geometry in
            StreamEdges(
                nearTop: geometry.visibleRect.minY < 600,
                atBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 60
            )
        } action: { _, value in
            edges = value
        }
        .onChange(of: edges.nearTop) { loadOlderIfNeeded() }
        .onChange(of: store.isLoadingOlder) { loadOlderIfNeeded() }
        .onChange(of: store.phase) { loadOlderIfNeeded() }
        .simultaneousGesture(TapGesture().onEnded {
            if composer.mentionQuery != nil { composer.dismissedQuery = composer.mentionQuery }
            composerFocused = false
        })
    }

    private func loadOlderIfNeeded() {
        guard edges.nearTop, store.phase == .loaded, store.hasOlder, !store.isLoadingOlder, !holdingForOlder else { return }
        holdingForOlder = true
        Task {
            await store.loadOlder()
            try? await Task.sleep(for: .milliseconds(250))
            holdingForOlder = false
        }
    }

    @ViewBuilder private var streamContent: some View {
        switch store.phase {
        case .idle, .loading:
            if showsSpinner {
                ProgressView()
                    .tint(.raftTextSecondary)
                    .padding(.top, 120)
                    .accessibilityLabel(Text(L10n.t("ios_loading", "Loading")))
            }
        case .failed:
            LoadErrorView(title: L10n.t("ios_chat_error_load", "Could not load messages"), top: 72) {
                Task { await store.loadLatest() }
            }
        case .loaded:
            if isEmpty {
                emptyState
            } else {
                if store.isLoadingOlder { LoadingOlderRow() }
                ForEach(entries) { entry in
                    entryView(entry)
                }
                if joinFlow.joinedHere {
                    JoinedSystemLine(name: store.title)
                        .padding(.top, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !store.typingAgentIds.isEmpty {
                    TypingRow(personas: store.typingAgentIds.map { workspace.directory.persona(type: "agent", id: $0, name: nil) })
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
            if isEmpty && joinFlow.joinedHere {
                JoinedSystemLine(name: store.title)
                    .padding(.top, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private func entryView(_ entry: ChatEntry) -> some View {
        switch entry.kind {
        case .date(let text):
            DateLine(text: text).padding(.top, 16)
        case .system(let message):
            SystemMessageRow(message: message).padding(.top, 16)
        case .message(let message, let continuation):
            let row = ChatRows.row(message, directory: workspace.directory, currentUserId: store.currentUserId, thread: store.threads[message.id])
            MessageRowView(
                row: row,
                context: context,
                continuation: continuation,
                showsAddReaction: !isPreview,
                highlighted: interactions.highlightedId == entry.id,
                interactive: !message.isDeleted,
                actions: actions(for: row)
            )
            .accessibilityFocused($focusedEntry, equals: entry.id)
            .padding(.top, continuation ? 6 : 16)
        case .pending(let pending, let continuation):
            let row = ChatRows.row(pending, me: me)
            MessageRowView(row: row, context: context, continuation: continuation, actions: actions(for: row))
                .padding(.top, continuation ? 6 : 16)
        }
    }

    // MARK: 14 Empty

    @ViewBuilder private var emptyState: some View {
        if isDirectMessage {
            EmptyStateView(
                title: L10n.f("ios_dm_empty_title", "This is the start of your conversation with %1$@", peer?.name ?? store.title),
                top: 24,
                horizontal: 24
            ) {
                if let peer { AvatarView(persona: peer, size: .lg) }
            }
        } else {
            EmptyStateView(
                title: L10n.f("ios_channel_empty_title", "This is the start of #%1$@", store.title.replacingOccurrences(of: "-", with: "\u{2011}")),
                detail: topic ?? L10n.t("ios_channel_empty_detail", "Share updates, files and questions with people and agents here."),
                top: 24,
                horizontal: 24
            ) {
                ChannelTile(large: true)
            }
        }
    }

    // MARK: Composer (§2.8)

    private var composerBar: some View {
        VStack(spacing: 8) {
            if store.isDetached {
                Button {
                    Task {
                        await store.jumpToLatest()
                        position.scrollTo(edge: .bottom)
                    }
                } label: {
                    Label(L10n.t("ios_jump_to_latest", "Jump to latest"), systemImage: "arrow.down")
                        .raftFont(.footnoteStrong)
                        .foregroundStyle(Color.raftTextPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .raftGlass(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            if let query = composer.mentionQuery, !mentionCandidates.isEmpty {
                MentionPicker(query: query, candidates: mentionCandidates, highlighted: min(composer.highlightedMention, mentionCandidates.count - 1)) { candidate in
                    composer.pick(candidate)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !isTask {
            ComposerPanel(
                mode: isDirectMessage ? .directMessage(peer?.name ?? store.title) : .channel(store.title),
                model: composer,
                focus: $composerFocused,
                candidates: mentionCandidates,
                send: send,
                pickPhotos: { pickingPhotos = true },
                takePhoto: { takingPhoto = true },
                pickFiles: { importingFiles = true },
                retryUpload: { id in
                    composer.retryUpload(id, channelId: store.channelId, api: workspace.api, readOnly: model.preferences.readOnly)
                },
                join: isPreview ? joinFlow.bar(channelId: store.channelId, name: store.title, workspace: workspace, reduceMotion: reduceMotion) : nil
            )
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, composerFocused ? 8 : -8)
        .animation(.smooth(duration: 0.2), value: mentionCandidates.isEmpty)
    }

    private func addFiles(_ files: [UploadFile]) {
        guard !files.isEmpty else { return }
        composer.add(files, channelId: store.channelId, api: workspace.api, readOnly: model.preferences.readOnly)
    }

    private func send() {
        guard composer.canSend else { return }
        guard !model.preferences.readOnly else {
            model.showToast(StoreError.readOnly.errorDescription ?? "")
            return
        }
        let draft = composer
        composer = ComposerModel()
        sendTick += 1
        // The row shows on the tap, marked as sending; uploads and the request follow.
        guard let randomId = store.enqueue(
            draft.text,
            mentions: draft.resolvedMentions,
            hasAttachments: !draft.attachments.isEmpty,
            attachmentNames: draft.attachments.map(\.filename),
            asTask: draft.asTask
        ) else { return }
        Task {
            await draft.waitForUploads()
            await store.deliver(randomId, attachmentIds: draft.uploadedIds)
        }
        withAnimation(.smooth(duration: 0.25)) { position.scrollTo(edge: .bottom) }
    }

    // MARK: Actions (§3-12, §3-15)

    private func react(_ messageId: String, _ emoji: String) {
        Task { await store.toggleReaction(emoji, on: messageId) }
    }

    private func actions(for row: MessageRowModel) -> MessageRowActions {
        var actions = MessageRowActions()
        if let message = row.message, isPreview {
            // Preview (§11 26): read-only. Chips do nothing; long press offers Copy text / link.
            actions.openThread = { openThread(message) }
            actions.copyLink = { copyLink(message) }
            actions.openAttachment = { open($0) }
            actions.copyText = { copy(row.plainText) }
            actions.longPress = { frame in lift(row, message: message, frame: frame) }
        } else if let message = row.message {
            actions.toggleReaction = { emoji in react(message.id, emoji) }
            actions.addReaction = { interactions.pickEmoji(for: message.id) }
            if !isTask {
                actions.openThread = { openThread(message) }
                actions.replyInThread = { openThread(message) }
                actions.copyLink = { copyLink(message) }
            }
            actions.openAttachment = { open($0) }
            actions.copyText = { copy(row.plainText) }
            actions.longPress = { frame in lift(row, message: message, frame: frame) }
        } else if let pending = row.pending {
            actions.retry = { Task { await store.retry(pending.randomId) } }
            actions.copyText = { copy(row.plainText) }
            actions.longPress = { frame in liftPending(row, pending: pending, frame: frame) }
        }
        return actions
    }

    private func lift(_ row: MessageRowModel, message: Message, frame: CGRect) {
        composerFocused = false
        var items = [
            MessageMenuItem(id: "reply", title: L10n.t("thread_action_reply_in_thread", "Reply in thread"), systemImage: "text.bubble") { openThread(message) },
            MessageMenuItem(id: "copy", title: L10n.t("file_preview_action_copy_text", "Copy text"), systemImage: "doc.on.doc") { copy(row.plainText) },
            MessageMenuItem(id: "react", title: L10n.t("thread_action_add_reaction", "Add reaction"), systemImage: "face.smiling") { interactions.pickEmoji(for: message.id) },
            MessageMenuItem(id: "link", title: L10n.t("thread_action_copy_link", "Copy link"), systemImage: "link") { copyLink(message) },
        ]
        if isTask { items.removeAll { $0.id == "reply" || $0.id == "link" } }
        if isPreview { items.removeAll { $0.id == "reply" || $0.id == "react" } }
        interactions.present(MessageActionTarget(
            row: row,
            frame: frame,
            context: context,
            reactionsEnabled: !isPreview,
            items: items,
            react: { emoji in react(message.id, emoji) },
            moreReactions: { interactions.pickEmoji(for: message.id) }
        ))
    }

    private func liftPending(_ row: MessageRowModel, pending: PendingSend, frame: CGRect) {
        composerFocused = false
        var items: [MessageMenuItem] = []
        if case .failed(let reason) = pending.state {
            items.append(MessageMenuItem(id: "retry", title: L10n.t("thread_send_failure_retry", "Retry"), systemImage: "arrow.clockwise") {
                Task { await store.retry(pending.randomId) }
            })
            items.append(MessageMenuItem(id: "copy", title: L10n.t("file_preview_action_copy_text", "Copy text"), systemImage: "doc.on.doc") { copy(row.plainText) })
            items.append(MessageMenuItem(id: "delete", title: L10n.t("common_delete", "Delete"), systemImage: "trash", destructive: true) {
                withAnimation { store.discard(pending.randomId) }
            })
            items.append(MessageMenuItem(id: "details", title: L10n.t("thread_send_failure_details", "Details"), systemImage: "info.circle") {
                interactions.showFailure(reason)
            })
        } else {
            items.append(MessageMenuItem(id: "copy", title: L10n.t("file_preview_action_copy_text", "Copy text"), systemImage: "doc.on.doc") { copy(row.plainText) })
        }
        interactions.present(MessageActionTarget(row: row, frame: frame, context: context, reactionsEnabled: false, items: items, react: { _ in }, moreReactions: {}))
    }

    private func openThread(_ message: Message) {
        let info = store.threads[message.id]
        model.push(.thread(ThreadRef(
            parentChannelId: store.channelId,
            parentMessageId: message.id,
            threadChannelId: info?.threadChannelId ?? message.threadSummary?.threadChannelId,
            title: store.title,
            parent: message
        )))
    }

    private func open(_ attachment: MessageAttachment) {
        Task {
            do {
                interactions.previewURL = try await workspace.attachments.localFile(for: attachment)
            } catch {
                model.showToast(ErrorText.describe(error))
            }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        model.showToast(L10n.t("common_copied", "Copied"))
    }

    private func copyLink(_ message: Message) {
        let url = Permalink.message(
            base: model.environment.webURL,
            serverSlug: model.servers.selectedServer?.slug,
            channelId: store.channelId,
            isDirectMessage: isDirectMessage,
            messageId: message.id
        )
        UIPasteboard.general.url = url
        model.showToast(L10n.t("common_copied", "Copied"))
    }
}
