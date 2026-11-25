import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: 16 Thread

struct ThreadView: View {
    let store: ThreadStore
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var composer = ComposerModel()
    @State private var interactions = MessageInteractions()
    @FocusState private var composerFocused: Bool
    @State private var position = ScrollPosition(edge: .top)
    @State private var edges = StreamEdges(nearTop: true, atBottom: false)
    @State private var holdingForOlder = false
    @State private var didScroll = false
    /// VoiceOver lands on the reply the thread opened at (29c).
    @AccessibilityFocusState private var focusedEntry: String?
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var sendTick = 0
    @State private var joinFlow = ChannelJoinFlow()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var replies: ConversationStore? { store.replies }

    private var context: ChatContext {
        ChatContext(
            currentUserId: workspace.currentUserId,
            channelNames: Set(workspace.channelList.channels.map { $0.name.lowercased() }),
            directory: workspace.directory,
            attachments: workspace.attachments
        )
    }

    private var parentIsDirectMessage: Bool { workspace.channelList.isDirectMessage(store.parentChannelId) }
    /// A thread of a previewed channel (§11 26): read-only, Join bar instead of the composer.
    private var isPreview: Bool { workspace.channelList.isPreview(store.parentChannelId) }
    private var parentChannelName: String { workspace.channelList.channel(id: store.parentChannelId)?.name ?? store.title }

    /// A DM parent shows the person or agent. Opened from Activity or Saved, `store.title` is the
    /// server's internal DM channel name (a handle), so prefer the DM row's peer name.
    private var subtitle: String {
        guard parentIsDirectMessage else { return "#\(store.title)" }
        let dm = workspace.channelList.directMessages.first { $0.id == store.parentChannelId }
        return dm?.displayTitle(currentUserId: workspace.currentUserId) ?? store.title
    }

    private var me: Persona {
        let user = model.session.user
        return workspace.directory.persona(type: "user", id: workspace.currentUserId, name: user?.displayName ?? user?.name, avatarURL: user?.avatarUrl)
    }

    private var replyCount: Int {
        max(store.replyCount ?? 0, replies?.messages.filter { !$0.isDeleted }.count ?? 0)
    }

    private var countText: String {
        replyCount == 1
            ? L10n.t("thread_inline_reply_count_one", "1 reply")
            : L10n.f("thread_inline_reply_count_many", "%1$d replies", replyCount)
    }

    private var mentionCandidates: [MentionCandidate] {
        guard let query = composer.mentionQuery else { return [] }
        return workspace.directory.mentionMatches(query, excluding: workspace.currentUserId)
    }

    private var uploadChannelId: String { store.threadChannelId ?? store.parentChannelId }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                content
            }
            .scrollTargetLayout()
            .padding(.bottom, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.top, for: .alignment)
        // Short content sits at the top (alignment): kept there as it grows. Pinning its bottom
        // instead pushed the parent up out of sight for a few frames when a reply was added.
        .defaultScrollAnchor(((edges.atBottom && edges.overflows) || holdingForOlder) ? .bottom : .top, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: StreamEdges.self) { geometry in
            StreamEdges(
                nearTop: geometry.visibleRect.minY < 600,
                atBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 60,
                overflows: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom > geometry.containerSize.height
            )
        } action: { _, value in
            edges = value
        }
        .onChange(of: edges.nearTop) { loadOlderIfNeeded() }
        .simultaneousGesture(TapGesture().onEnded {
            if composer.mentionQuery != nil { composer.dismissedQuery = composer.mentionQuery }
            composerFocused = false
        })
        .background(Color.raftCanvas.ignoresSafeArea())
        .raftNavigationTitle(L10n.t("thread_reply_title", "Thread"), subtitle: subtitle)
        .toolbar {
            if !isPreview {
            ToolbarItem(placement: .topBarTrailing) {
                let following = store.isFollowing == true
                Button {
                    Task { await store.setFollowing(!following) }
                } label: {
                    Image(systemName: following ? "bell.fill" : "bell")
                }
                .accessibilityLabel(Text(following ? L10n.t("thread_action_unfollow_thread", "Unfollow thread") : L10n.t("thread_action_follow_thread", "Follow thread")))
                .accessibilityIdentifier("thread-follow")
            }
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
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(AttachmentImport.load(urls)) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
        .sensoryFeedback(.impact(weight: .light), trigger: joinFlow.tapTick)
        .sensoryFeedback(.success, trigger: joinFlow.successTick)
        .sensoryFeedback(.error, trigger: joinFlow.errorTick)
        // The keyboard and the composer's collapse/expand change the bottom inset together;
        // the bottom anchor can overshoot past the last message. Re-pin when it was at the bottom.
        .onChange(of: composerFocused) {
            guard edges.atBottom else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(380))
                // By id: `scrollTo(edge:)` is a no-op here, the position still reads as "bottom".
                if let last = replies.flatMap({ replyEntries(messages: $0.messages, pending: $0.pending).last?.id }) {
                    withAnimation(.smooth(duration: 0.2)) { position.scrollTo(id: last, anchor: .bottom) }
                }
            }
        }
        .task {
            await store.start()
            replies?.isVisible = scenePhase == .active
            await scrollToStart()
        }
        .savedChecks(workspace.saved, ids: [store.parentMessageId] + (replies?.messages.map(\.id) ?? []), page: store.phase == .loaded ? (replies?.messages.first?.id ?? store.parentMessageId) : nil)
        .onAppear { replies?.isVisible = scenePhase == .active }
        .onDisappear { replies?.isVisible = false }
        .onChange(of: scenePhase) { _, phase in replies?.isVisible = phase == .active }
        .onChange(of: store.errorMessage) { _, message in
            guard let message else { return }
            model.showToast(message)
            store.errorMessage = nil
        }
        .onChange(of: replies?.errorMessage) { _, message in
            guard let message else { return }
            model.showToast(message)
            replies?.errorMessage = nil
        }
    }

    /// Many replies: the newest, or the focused / first unread one (§3-16).
    private func scrollToStart() async {
        guard !didScroll, let replies, !replies.messages.isEmpty else { return }
        didScroll = true
        try? await Task.sleep(for: .milliseconds(120))
        if let focus = replies.focusMessageId {
            position.scrollTo(id: "m:\(focus)", anchor: .center)
            interactions.flash("m:\(focus)")
            focusedEntry = "m:\(focus)"
        } else if let marker = replies.unreadMarkerSeq, let first = replies.messages.first(where: { ($0.seq ?? 0) > marker }), first.id != replies.messages.first?.id {
            position.scrollTo(id: "m:\(first.id)", anchor: .top)
        } else if replies.messages.count > 4 {
            position.scrollTo(edge: .bottom)
        }
    }

    private func loadOlderIfNeeded() {
        guard edges.nearTop, let replies, replies.phase == .loaded, replies.hasOlder, !replies.isLoadingOlder, !holdingForOlder else { return }
        holdingForOlder = true
        Task {
            await replies.loadOlder()
            try? await Task.sleep(for: .milliseconds(250))
            holdingForOlder = false
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView()
                .tint(.raftTextSecondary)
                .padding(.top, 120)
                .accessibilityLabel(Text(L10n.t("ios_loading", "Loading")))
        case .failed:
            LoadErrorView(title: L10n.t("ios_thread_error_load", "Could not load this thread"), top: 72) {
                Task { await store.start() }
            }
        case .loaded:
            if let parent = store.parent {
                let row = ChatRows.row(parent, directory: workspace.directory, currentUserId: workspace.currentUserId, thread: nil)
                MessageRowView(row: row, context: context, showsAddReaction: !isPreview, interactive: !parent.isDeleted, actions: parentActions(row, parent))
                    .padding(.top, 12)
            }
            DateLine(text: countText, strong: true)
                .padding(.vertical, 16)
                .contentTransition(.numericText())
            if let replies {
                if replies.isLoadingOlder { LoadingOlderRow() }
                let entries = replyEntries(messages: replies.messages, pending: replies.pending)
                ForEach(entries) { entry in
                    entryView(entry, first: entry.id == entries.first?.id)
                }
            }
            // Replies sent while the thread is being created (it has no store yet).
            if !store.pendingBeforeThread.isEmpty {
                let entries = replyEntries(messages: [], pending: store.pendingBeforeThread)
                ForEach(entries) { entry in
                    entryView(entry, first: entry.id == entries.first?.id)
                }
            }
            if let replies {
                if !replies.typingAgentIds.isEmpty {
                    TypingRow(personas: replies.typingAgentIds.map { workspace.directory.persona(type: "agent", id: $0, name: nil) })
                        .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder private func entryView(_ entry: ChatEntry, first: Bool) -> some View {
        switch entry.kind {
        case .date(let text):
            DateLine(text: text).padding(.top, first ? 0 : 16)
        case .system(let message):
            SystemMessageRow(message: message).padding(.top, first ? 0 : 16)
        case .message(let message, let continuation):
            let row = ChatRows.row(message, directory: workspace.directory, currentUserId: workspace.currentUserId, thread: nil)
            MessageRowView(
                row: row,
                context: context,
                continuation: continuation,
                showsAddReaction: !isPreview,
                highlighted: interactions.highlightedId == entry.id,
                interactive: !message.isDeleted,
                actions: replyActions(row, message)
            )
            .accessibilityFocused($focusedEntry, equals: entry.id)
            .padding(.top, first ? 0 : (continuation ? 6 : 16))
        case .pending(let pending, let continuation):
            let row = ChatRows.row(pending, me: me)
            MessageRowView(row: row, context: context, continuation: continuation, actions: pendingActions(row, pending))
                .padding(.top, first ? 0 : (continuation ? 6 : 16))
        }
    }

    /// Replies with their date lines; the first line goes when it is the parent's day (the
    /// "N replies" line already separates them).
    private func replyEntries(messages: [Message], pending: [PendingSend]) -> [ChatEntry] {
        var list = ChatTimeline.entries(messages: messages, pending: pending, currentUserId: workspace.currentUserId)
        if let first = list.first, case .date = first.kind,
           let parentDate = store.parent?.createdDate,
           let firstDate = messages.first?.createdDate ?? pending.first?.createdAt,
           Calendar.current.isDate(firstDate, inSameDayAs: parentDate) {
            list.removeFirst()
        }
        return list
    }

    // MARK: Composer

    private var composerBar: some View {
        VStack(spacing: 8) {
            if let query = composer.mentionQuery, !mentionCandidates.isEmpty {
                MentionPicker(query: query, candidates: mentionCandidates, highlighted: min(composer.highlightedMention, mentionCandidates.count - 1)) { candidate in
                    composer.pick(candidate)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            ComposerPanel(
                mode: .thread,
                model: composer,
                focus: $composerFocused,
                candidates: mentionCandidates,
                send: send,
                pickPhotos: { pickingPhotos = true },
                pickFiles: { importingFiles = true },
                retryUpload: { id in
                    composer.retryUpload(id, channelId: uploadChannelId, api: workspace.api, readOnly: model.preferences.readOnly)
                },
                join: isPreview ? joinFlow.bar(channelId: store.parentChannelId, name: parentChannelName, workspace: workspace, reduceMotion: reduceMotion) : nil
            )
            .disabled(store.phase != .loaded && !isPreview)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, composerFocused ? 8 : -8)
        .animation(.smooth(duration: 0.2), value: mentionCandidates.isEmpty)
    }

    private func addFiles(_ files: [UploadFile]) {
        guard !files.isEmpty else { return }
        composer.add(files, channelId: uploadChannelId, api: workspace.api, readOnly: model.preferences.readOnly)
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
        // The row shows on the tap, marked as sending; thread creation, uploads and the request
        // follow.
        guard let randomId = store.enqueueReply(
            draft.text,
            mentions: draft.resolvedMentions,
            hasAttachments: !draft.attachments.isEmpty,
            attachmentNames: draft.attachments.map(\.filename)
        ) else { return }
        Task {
            await revealLatest()
            await draft.waitForUploads()
            await store.deliverReply(randomId, attachmentIds: draft.uploadedIds)
            replies?.isVisible = scenePhase == .active
            await revealLatest()
        }
    }

    /// Scrolls to the newest reply once the new row is laid out, only when the thread is taller
    /// than the screen. Short content needs no scroll, and asking for the bottom edge then
    /// pushed the parent up out of sight for a few frames.
    private func revealLatest() async {
        await Task.yield()
        guard edges.overflows else { return }
        withAnimation(.smooth(duration: 0.25)) { position.scrollTo(edge: .bottom) }
    }

    // MARK: Actions

    private func react(_ messageId: String, _ emoji: String) {
        if messageId == store.parentMessageId, let parent = store.parent {
            Task {
                do {
                    try await workspace.toggleReaction(emoji, on: parent)
                } catch {
                    model.showToast(ErrorText.describe(error))
                }
            }
        } else {
            Task { await replies?.toggleReaction(emoji, on: messageId) }
        }
    }

    /// Preview: chips do nothing, long press offers Copy text / Copy link.
    private func previewActions(_ row: MessageRowModel, _ message: Message, isReply: Bool) -> MessageRowActions {
        var actions = MessageRowActions()
        actions.openAttachment = { open($0) }
        actions.copyText = { copy(row.plainText) }
        actions.copyLink = { copyLink(message, isReply: isReply) }
        actions.longPress = { frame in lift(row, message, frame: frame, isReply: isReply) }
        return actions
    }

    private func parentActions(_ row: MessageRowModel, _ message: Message) -> MessageRowActions {
        if isPreview { return previewActions(row, message, isReply: false) }
        var actions = MessageRowActions()
        actions.toggleReaction = { emoji in react(message.id, emoji) }
        actions.addReaction = { interactions.pickEmoji(for: message.id) }
        actions.openAttachment = { open($0) }
        actions.copyText = { copy(row.plainText) }
        actions.copyLink = { copyLink(message, isReply: false) }
        actions.replyInThread = { composerFocused = true }
        actions.toggleSaved = workspace.saved.toggleAction(for: message)
        actions.longPress = { frame in lift(row, message, frame: frame, isReply: false) }
        return actions
    }

    private func replyActions(_ row: MessageRowModel, _ message: Message) -> MessageRowActions {
        if isPreview { return previewActions(row, message, isReply: true) }
        var actions = MessageRowActions()
        actions.toggleReaction = { emoji in react(message.id, emoji) }
        actions.addReaction = { interactions.pickEmoji(for: message.id) }
        actions.openAttachment = { open($0) }
        actions.copyText = { copy(row.plainText) }
        actions.copyLink = { copyLink(message, isReply: true) }
        actions.replyInThread = { composerFocused = true }
        actions.toggleSaved = workspace.saved.toggleAction(for: message)
        actions.longPress = { frame in lift(row, message, frame: frame, isReply: true) }
        return actions
    }

    /// A failed reply: in the replies store, or the first reply whose thread was not created.
    private func retry(_ randomId: String) {
        Task {
            if store.pendingBeforeThread.contains(where: { $0.randomId == randomId }) {
                await store.retryBeforeThread(randomId)
            } else {
                await replies?.retry(randomId)
            }
        }
    }

    private func pendingActions(_ row: MessageRowModel, _ pending: PendingSend) -> MessageRowActions {
        var actions = MessageRowActions()
        actions.retry = { retry(pending.randomId) }
        actions.copyText = { copy(row.plainText) }
        actions.longPress = { frame in
            composerFocused = false
            var items = [MessageMenuItem(id: "copy", title: L10n.t("file_preview_action_copy_text", "Copy text"), systemImage: "doc.on.doc") { copy(row.plainText) }]
            if case .failed(let reason) = pending.state {
                items.insert(MessageMenuItem(id: "retry", title: L10n.t("thread_send_failure_retry", "Retry"), systemImage: "arrow.clockwise") {
                    retry(pending.randomId)
                }, at: 0)
                items.append(MessageMenuItem(id: "delete", title: L10n.t("common_delete", "Delete"), systemImage: "trash", destructive: true) {
                    withAnimation {
                        replies?.discard(pending.randomId)
                        store.discardBeforeThread(pending.randomId)
                    }
                })
                items.append(MessageMenuItem(id: "details", title: L10n.t("thread_send_failure_details", "Details"), systemImage: "info.circle") {
                    interactions.showFailure(reason)
                })
            }
            interactions.present(MessageActionTarget(row: row, frame: frame, context: context, reactionsEnabled: false, items: items, react: { _ in }, moreReactions: {}))
        }
        return actions
    }

    private func lift(_ row: MessageRowModel, _ message: Message, frame: CGRect, isReply: Bool) {
        composerFocused = false
        var items = [
            MessageMenuItem(id: "copy", title: L10n.t("file_preview_action_copy_text", "Copy text"), systemImage: "doc.on.doc") { copy(row.plainText) },
            MessageMenuItem(id: "react", title: L10n.t("thread_action_add_reaction", "Add reaction"), systemImage: "face.smiling") { interactions.pickEmoji(for: message.id) },
            MessageMenuItem(id: "link", title: L10n.t("thread_action_copy_link", "Copy link"), systemImage: "link") { copyLink(message, isReply: isReply) },
        ]
        if isPreview { items.removeAll { $0.id == "react" } }
        if !isPreview, let save = workspace.saved.menuItem(for: message) { items.insert(save, at: 0) }
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

    private func copyLink(_ message: Message, isReply: Bool) {
        let thread = isReply ? store.threadChannelId.map { (channelId: $0, parentId: store.parentMessageId) } : nil
        let url = Permalink.message(
            base: model.environment.webURL,
            serverSlug: model.servers.selectedServer?.slug,
            channelId: store.parentChannelId,
            isDirectMessage: parentIsDirectMessage,
            messageId: message.id,
            thread: thread
        )
        UIPasteboard.general.url = url
        model.showToast(L10n.t("common_copied", "Copied"))
    }
}
