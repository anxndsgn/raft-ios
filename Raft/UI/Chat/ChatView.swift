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

/// The stream's scroll geometry, kept for landing on a message (29c). `top` is the content y at
/// the top of the visible area (under the bars); `visible` is that area's height.
struct StreamGeometry: Equatable {
    var top: CGFloat = 0
    var visible: CGFloat = 0
    var contentHeight: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        top = geometry.contentOffset.y + geometry.contentInsets.top
        visible = geometry.containerSize.height
        contentHeight = geometry.contentSize.height
    }

    /// The largest visible-top content y: the content's end at the bottom of the visible area.
    var maxTop: CGFloat { max(contentHeight - visible, 0) }

    /// The visible-top content y that centres `frame`, kept inside the scrollable range.
    func centring(_ frame: CGRect) -> CGFloat {
        let wanted = frame.midY - visible / 2
        return min(max(wanted, 0), maxTop)
    }
}

/// The stream's last row end: in the content (`AnchoredLanding.space`) and on screen.
struct StreamEnd: Equatable {
    var content: CGFloat
    var screen: CGFloat
}

/// Jump to latest (5595): a glass circle centred 12pt above the bottom bar, shown while the list
/// is more than a screen from its end. An overlay of the bar: it moves with the bar (the keyboard,
/// the composer growing) and never changes the bar's height, so the list does not move.
struct JumpToLatestButton: View {
    let isShown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.t("ios_jump_to_latest", "Jump to latest")))
        .accessibilityHint(Text(L10n.t("ios_jump_to_latest_hint", "Scrolls to the newest message")))
        .scaleEffect(isShown ? 1 : 0.8)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isShown)
    }
}

extension View {
    /// The jump-to-latest button over this bottom bar, its bottom 12pt above the bar's top.
    func jumpToLatest(shown: Bool, action: @escaping () -> Void) -> some View {
        overlay(alignment: .top) {
            JumpToLatestButton(isShown: shown, action: action)
                .alignmentGuide(.top) { $0[.bottom] + 12 }
        }
    }
}

/// Whether the visible area's bottom is more than a screen (the visible height) above the end.
func isFarFromEnd(_ geometry: ScrollGeometry) -> Bool {
    geometry.contentSize.height - geometry.visibleRect.maxY > geometry.containerSize.height
}

/// Opening at a message (29c). The stream stays hidden until the row is where it will stay, so it
/// lands once: centred when it can be, else as near the centre as the content allows (at the
/// top or the bottom). The last step is an offset, not "this id at the centre": an id-based
/// position is resolved again on later layout passes (the flash ending was one), and with the
/// estimated sizes of lazy rows that moved the content 60–70pt past its end and back.
///
/// The landing always ends, by `deadline` at the latest: a target that is not in the stream, or
/// whose frame is never reported, lands on the stream's resting edge instead (still as an offset).
/// Left on the id, a short stream could stay scrolled out of sight until the user scrolled.
@MainActor
enum AnchoredLanding {
    static let space = "anchored-stream"
    /// How long the target row has to report its frame before the stream is shown anyway.
    static let deadline: Duration = .milliseconds(300)

    /// The final position.
    enum Step: Equatable {
        /// A visible-top content y.
        case offset(CGFloat)
        /// No usable geometry yet: the edge the stream rests on.
        case edge(Edge)
    }

    /// Where the stream ends up: the target centred (clamped to the content), else the resting
    /// edge as an offset. Short content (shorter than the visible area) clamps to 0.
    static func finalStep(frame: CGRect?, geometry: StreamGeometry, resting: Edge) -> Step {
        guard geometry.visible > 0 else { return .edge(resting) }
        if let frame { return .offset(geometry.centring(frame)) }
        return .offset(resting == .top ? 0 : geometry.maxTop)
    }

    static func land(
        on entryId: String,
        present: Bool,
        resting: Edge,
        position: Binding<ScrollPosition>,
        geometry: () -> StreamGeometry,
        target: () -> CGRect?
    ) async {
        func apply(_ step: Step) {
            switch step {
            case .offset(let y): position.wrappedValue.scrollTo(y: y)
            case .edge(let edge): position.wrappedValue.scrollTo(edge: edge)
            }
        }
        // Not loaded (another page, or not a row of this stream): nothing to wait for.
        guard present else {
            apply(finalStep(frame: nil, geometry: geometry(), resting: resting))
            try? await Task.sleep(for: .milliseconds(50))
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        position.wrappedValue.scrollTo(id: entryId, anchor: .center)
        // Two layout passes: the lazy rows around the target are measured.
        try? await Task.sleep(for: .milliseconds(100))
        position.wrappedValue.scrollTo(id: entryId, anchor: .center)
        try? await Task.sleep(for: .milliseconds(60))
        while target() == nil, clock.now - start < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Always, even when already there: the position then holds an offset, not the id.
        apply(finalStep(frame: target(), geometry: geometry(), resting: resting))
        try? await Task.sleep(for: .milliseconds(50))
    }
}

extension View {
    /// The row's frame in the stream's content, reported while it is the landing target. Always
    /// attached (not `if`): switching would rebuild the row when the landing ends.
    func landingFrame(_ isTarget: Bool, _ report: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect?.self) { isTarget ? $0.frame(in: .named(AnchoredLanding.space)) : nil } action: { frame in
            if let frame { report(frame) }
        }
    }
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
    /// The list is held on its last message (`holdBottom`): from the start, unless it opens at a
    /// message; after a scroll, when it comes to rest at the bottom.
    @State private var holdsBottom: Bool
    /// Until the first settle in `start()`: the bars' insets and the rows' real heights arrive
    /// over the first layout passes, and the list is kept on its last message through all of them.
    @State private var opening = true
    @State private var scrollIdle = true
    @State private var edges = StreamEdges(nearTop: false, atBottom: true)
    @State private var holdingForOlder = false
    @State private var showsBanner = false
    @State private var showsSpinner = false
    @State private var didFocus = false
    /// Opening at a message: the stream is hidden until it has landed there (29c).
    @State private var landing: Bool
    @State private var geometry = StreamGeometry()
    /// Where the last row really ends (`StreamEnd`) and the bottom bar's top, on screen.
    @State private var streamEnd: StreamEnd?
    @State private var barTop: CGFloat?
    /// Opening on the last message: the list stays hidden until both the scroll geometry and
    /// the laid-out last row agree it is there. The first passes placed it the bottom bar's height
    /// (86pt) past its end, then corrected it, which flashed.
    @State private var endSettled = false
    /// More than a screen from the end: the jump-to-latest button shows.
    @State private var farFromEnd = false
    @State private var landingTarget: String?
    @State private var targetFrame: CGRect?
    /// VoiceOver lands on the message the conversation opened at (29c).
    @AccessibilityFocusState private var focusedEntry: String?
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var importingFiles = false
    @State private var sendTick = 0
    @State private var joinFlow = ChannelJoinFlow()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    init(store: ConversationStore, ref: ConversationRef) {
        self.store = store
        self.ref = ref
        _landing = State(initialValue: ref.focusMessageId != nil)
        _holdsBottom = State(initialValue: ref.focusMessageId == nil)
    }

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

    /// The peer the DM header (33a) shows; `nil` in channels and tasks, and in a DM whose row has
    /// not loaded yet (the system title shows the name until then).
    private var dmHeaderPeer: Persona? { isDirectMessage ? peer : nil }

    /// Opens the DM info page from ⓘ and the header. `nil`: there is no such page yet, and
    /// §10-2 hides entries without a target, so neither is shown as a button.
    private var dmInfo: (() -> Void)? { nil }

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
        VerticalBarReader { vertical in page(verticalBar: vertical) }
    }

    /// `verticalBar`: the system stacks the bars on the trailing edge (Duo folded, unfolded
    /// landscape). The title then sits at the top of the content (大字号补充 A.4) instead of
    /// floating over the messages.
    private func page(verticalBar: Bool) -> some View {
        stream
            .background(Color.raftCanvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: peerTitle ?? store.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if dmHeaderPeer == nil {
                    ToolbarItem(placement: .principal) {
                        if verticalBar {
                            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                        } else {
                            title
                        }
                    }
                } else {
                    // A DM shows its peer under the bar (33a); the bar keeps only back and ⓘ
                    // (vertical on Duo folded / unfolded landscape), and the title stays for
                    // VoiceOver and the back menu.
                    ToolbarItem(placement: .principal) {
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                    if let dmInfo {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: dmInfo) {
                                Label(L10n.t("ios_dm_info", "Conversation info"), systemImage: "info.circle")
                            }
                            .raftLargeContent(systemImage: "info.circle", label: L10n.t("ios_dm_info", "Conversation info"))
                            .accessibilityIdentifier("dm-info")
                        }
                    }
                }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let peer = dmHeaderPeer {
                        DMHeaderBar(peer: peer, name: peerTitle ?? peer.name, subtitle: dmSubtitle(peer), info: dmInfo)
                    } else if verticalBar {
                        TopTitleBlock { title }
                    }
                    if showsBanner {
                        StatusBanner(updatedAt: workspace.lastConnectedAt)
                            .padding(.vertical, 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
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
            .savedChecks(workspace.saved, ids: store.messages.map(\.id), page: store.phase == .loaded ? store.messages.first?.id : nil)
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
            landing = false
            // Lazy rows are measured as they appear; settle on the real bottom once they are.
            if !didFocus {
                didFocus = true
                try? await Task.sleep(for: .milliseconds(150))
                if holdsBottom { settleOnEnd(force: true) }
                opening = false
            }
            return
        }
        didFocus = true
        let id = "m:\(focus)"
        landing = true
        targetFrame = nil
        landingTarget = id
        await AnchoredLanding.land(
            on: id,
            present: entries.contains { $0.id == id },
            resting: .bottom,
            position: $position,
            geometry: { geometry },
            target: { targetFrame }
        )
        landingTarget = nil
        // Shown with the highlight on: the 1.2s hold counts from here, when the row is on screen.
        landing = false
        interactions.flash(id)
        focusedEntry = id
    }

    // MARK: Title (§2.12, 10)

    @ViewBuilder private var title: some View {
        // A DM with its peer loaded shows it under the bar (`DMHeaderBar`).
        if isTask || isDirectMessage {
            NavTitle(title: store.title, hashPrefix: !isDirectMessage, subtitle: isDirectMessage ? nil : (ref.subtitle ?? topic), typeSize: typeSize)
        } else {
            // A channel: the title opens Channel info (§11 27).
            Button {
                model.push(.channelInfo(store.channelId))
            } label: {
                NavTitle(title: store.title, hashPrefix: true, subtitle: channelSubtitle, typeSize: typeSize)
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

    /// An agent: its runtime only ("Claude Code"); the dot by its name already shows presence
    /// (5577). A person: the presence word ("Online").
    private func dmSubtitle(_ peer: Persona) -> String? {
        if peer.kind == .agent { return peer.runtime }
        return peer.presence?.label
    }

    // MARK: Stream (§2.6)

    private var stream: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                streamContent
                // The end of the last row, as laid out: the scroll geometry's content height is an
                // estimate of the lazy rows and was not always reported again once they were
                // measured (a DM opened 86pt past its end, below an empty band).
                Color.clear.frame(height: 0)
                    .onGeometryChange(for: StreamEnd.self) { g in
                        StreamEnd(content: g.frame(in: .named(AnchoredLanding.space)).maxY, screen: g.frame(in: .global).maxY)
                    } action: { old, new in
                        streamEnd = new
                        if new.content != old.content || opening { settleOnEnd(force: false) }
                        checkEndSettled()
                    }
            }
            .scrollTargetLayout()
            .coordinateSpace(name: AnchoredLanding.space)
            .padding(.bottom, 12)
            .opacity(store.phase == .loaded && (landing || (opening && holdsBottom && !endSettled)) ? 0 : 1)
        }
        // A tap on the messages ends writing. On the scroll view itself, inside the bottom bar:
        // over the whole page it also saw taps in the composer (As task, +, send) and dropped the
        // keyboard on each.
        .simultaneousGesture(TapGesture().onEnded {
            if composer.mentionQuery != nil { composer.dismissedQuery = composer.mentionQuery }
            composerFocused = false
        })
        // The composer (and the join bar) is the scroll view's own bottom bar (it insets the
        // content); its edge effect is hidden below.
        .safeAreaBar(edge: .bottom) {
            composerBar
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barTop = $0 }
                .jumpToLatest(shown: (farFromEnd || store.isDetached) && !landing && store.phase == .loaded, action: scrollToLatest)
        }
        .composerPageBottom()
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor((isEmpty || store.isLoadingOlder || store.phase != .loaded) ? .top : .bottom, for: .alignment)
        .defaultScrollAnchor((edges.atBottom || holdingForOlder) ? .bottom : .top, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        // System soft fade under the nav bar (§2.12); no custom bar background or divider. None
        // at the bottom: messages pass under the composer's glass unblurred.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .onScrollGeometryChange(for: StreamEdges.self) { geometry in
            StreamEdges(
                nearTop: geometry.visibleRect.minY < 600,
                atBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 60
            )
        } action: { _, value in
            edges = value
        }
        .onScrollGeometryChange(for: StreamGeometry.self) { StreamGeometry($0) } action: { old, value in
            geometry = value
            holdBottom(old: old, new: value)
            checkEndSettled()
        }
        .onScrollGeometryChange(for: Bool.self, of: isFarFromEnd) { _, far in farFromEnd = far }
        .onScrollPhaseChange { old, phase in
            scrollIdle = phase == .idle
            if phase == .interacting {
                holdsBottom = false
                opening = false
            } else if phase == .idle, old == .interacting || old == .decelerating {
                // The user's scroll came to rest: held again when it rests at the bottom.
                holdsBottom = edges.atBottom && !landing
            }
        }
        .onChange(of: edges.nearTop) { loadOlderIfNeeded() }
        .onChange(of: store.isLoadingOlder) { loadOlderIfNeeded() }
        .onChange(of: store.phase) { loadOlderIfNeeded() }
    }

    /// Keeps the last message at the bottom while the list is held there: while it opens and
    /// whenever the content's height changes under it (an image loads, a message arrives). By
    /// offset, not by the bottom edge: an edge position (the initial one, `scrollTo(edge:)`, the
    /// bottom size-change anchor) is resolved again on later layout passes and lands the bottom
    /// bar's height (86pt) past the end, with the top inset still missing in the first pass; the
    /// list then jumped down when the settle in `start()` corrected it.
    private func holdBottom(old: StreamGeometry, new: StreamGeometry) {
        // Older messages loading above keep the bottom too (the size-change anchor is the bottom then).
        guard holdsBottom, scrollIdle, !landing, store.phase == .loaded,
              new.visible > 0, new.contentHeight > new.visible else { return }
        // Once open, a change of the visible height alone (the keyboard, the composer growing) is
        // left to the animated re-pin on focus.
        guard opening || new.contentHeight != old.contentHeight || new.visible == old.visible else { return }
        let target = endTop(visible: new.visible) ?? new.maxTop
        guard abs(new.top - target) >= 0.5 else { return }
        position.scrollTo(y: target)
    }

    /// The visible-top content y that puts the last row's end (and the list's 12pt bottom
    /// padding) at the bottom bar's top; nil before the end is laid out.
    private func endTop(visible: CGFloat) -> CGFloat? {
        guard let streamEnd, visible > 0 else { return nil }
        return max(streamEnd.content + 12 - visible, 0)
    }

    private func checkEndSettled() {
        guard opening, !endSettled, let streamEnd, let barTop, let target = endTop(visible: geometry.visible) else { return }
        // Short content (it cannot reach the bar) shows where it lies.
        if streamEnd.content + 12 <= geometry.visible || (abs(barTop - (streamEnd.screen + 12)) < 0.5 && abs(geometry.top - target) < 0.5) {
            endSettled = true
        }
    }

    /// Puts the last row's end on the bottom bar's top when it is not, measured on screen: that
    /// holds whatever the scroll geometry last reported. `force`: the settle in `start()`;
    /// otherwise only while held. Content shorter than the visible area is left where it is.
    private func settleOnEnd(force: Bool) {
        guard holdsBottom, force || scrollIdle, !landing, store.phase == .loaded,
              let streamEnd, let barTop, let target = endTop(visible: geometry.visible),
              streamEnd.content + 12 > geometry.visible else { return }
        let gap = barTop - (streamEnd.screen + 12)
        guard abs(gap) >= 0.5 else { return }
        position.scrollTo(y: target)
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
            SystemMessageRow(message: message)
                .landingFrame(landingTarget == entry.id) { targetFrame = $0 }
                .padding(.top, 16)
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
            .landingFrame(landingTarget == entry.id) { targetFrame = $0 }
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
                isPickingAttachment: pickingPhotos || takingPhoto || importingFiles,
                retryUpload: { id in
                    composer.retryUpload(id, channelId: store.channelId, api: workspace.api, readOnly: model.preferences.readOnly)
                },
                join: isPreview ? joinFlow.bar(channelId: store.channelId, name: store.title, workspace: workspace, reduceMotion: reduceMotion) : nil
            )
            }
        }
        .composerBarInsets(focused: composerFocused)
        .animation(.smooth(duration: 0.2), value: mentionCandidates.isEmpty)
    }

    /// Scrolls to the newest message, animated, and holds the list there. Detached (opened at
    /// an older message), the newest page is loaded first.
    private func scrollToLatest() {
        Task {
            if store.isDetached { await store.jumpToLatest() }
            holdsBottom = true
            withAnimation(.smooth(duration: 0.35)) {
                position.scrollTo(edge: .bottom)
            } completion: {
                // The animation ends where the lazy rows' estimates put the end: settled on the
                // last row's laid-out end.
                settleOnEnd(force: true)
            }
        }
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
            actions.toggleSaved = workspace.saved.toggleAction(for: message)
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
        if !isPreview, let save = workspace.saved.menuItem(for: message) {
            items.insert(save, at: items.first?.id == "reply" ? 1 : 0)
        }
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
