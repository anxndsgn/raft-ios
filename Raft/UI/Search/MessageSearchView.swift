import SwiftUI

// MARK: 06e entry · 29 / 29b / 29d / 29e Message search

/// The search page zooms out of Home's search button (06e).
@MainActor
enum MessageSearchZoom {
    static let sourceId = "search"
    /// Home's namespace, set while Home is on screen.
    static var namespace: Namespace.ID?
}

/// Home's search button left of the bell (06e), and the fixed gap that keeps the two from
/// merging into one capsule.
struct HomeSearchToolbarItems: ToolbarContent {
    let namespace: Namespace.ID
    let serverName: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(value: AppRoute.messageSearch) {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel(Text(L10n.t("home_nav_search", "Search")))
            .raftLargeContent(systemImage: "magnifyingglass", label: L10n.t("home_nav_search", "Search"))
            .accessibilityHint(Text(L10n.f("ios_search_messages_in", "Search messages in %1$@", serverName)))
            .accessibilityIdentifier("home-search")
        }
        .matchedTransitionSource(id: MessageSearchZoom.sourceId, in: namespace)
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
    }
}

/// `AppRoute.messageSearch`: the page, zooming from Home's button (a plain push with Reduce
/// Motion).
struct MessageSearchDestination: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let namespace = MessageSearchZoom.namespace, !reduceMotion {
            MessageSearchView(workspace: workspace)
                .navigationTransition(.zoom(sourceID: MessageSearchZoom.sourceId, in: namespace))
        } else {
            MessageSearchView(workspace: workspace)
        }
    }
}

// MARK: 29: the page

struct MessageSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var store: MessageSearchStore
    @FocusState private var fieldFocused: Bool
    @State private var didAppear = false
    @State private var announcedCount: Int?

    init(workspace: Workspace) {
        _store = State(initialValue: Self.makeStore(workspace))
    }

    private static func makeStore(_ workspace: Workspace) -> MessageSearchStore {
        #if DEBUG
        if let seeded = PreviewGallery.takeSearchStore() { return seeded }
        #endif
        return MessageSearchStore(
            api: workspace.api,
            recent: RecentSearches(serverId: workspace.serverId, userId: workspace.currentUserId),
            isOffline: { [weak workspace] in workspace?.isOffline ?? false }
        )
    }

    private var serverName: String { model.servers.selectedServer?.displayName ?? "" }

    var body: some View {
        @Bindable var store = store
        ScrollView {
            LazyVStack(spacing: 0) {
                content
                Color.clear.frame(height: 24)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color.raftCanvasWarm.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Our own bar (not `.searchable`): the field and the × stay on one row, focused or not,
        // so the results never move when the keyboard comes or goes.
        .safeAreaBar(edge: .top, spacing: 0) {
            SearchHeader(
                text: $store.text,
                prompt: L10n.t("ios_search_messages_prompt", "Search messages"),
                focus: $fieldFocused,
                submit: { store.submit() },
                close: cancel,
                top: 12
            )
        }
        .onChange(of: store.text) { store.textChanged() }
        .onChange(of: store.resultsVersion) { announceResults() }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            #if DEBUG
            if let screen = PreviewGallery.screen, ["29b", "29c"].contains(screen) { return }
            #endif
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                fieldFocused = true
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if store.showsRecent {
            recentSearches
        } else {
            switch store.phase {
            case .idle, .loading:
                MessageResultSkeleton()
                    .padding(.top, 12)
            case .failed(let offline):
                RaftGroupCard {
                    SearchRetryRow(title: offline
                        ? L10n.t("search_error_offline_detail", "Check your connection, then retry search.")
                        : L10n.t("ios_search_failed", "Couldn’t search messages.")
                    ) { store.retry() }
                }
                .padding(.top, 12)
            case .loaded:
                if store.results.isEmpty {
                    SearchEmptyBlock(
                        title: L10n.f("ios_search_no_match", "No messages match “%1$@”", store.query),
                        detail: store.isRelaxedSkipped
                            ? L10n.t("search_too_broad_hint", "No message contains all of these words, and too many contain one of them to check each one. Try more specific words.")
                            : L10n.t("ios_search_try_fewer", "Try fewer words."),
                        top: 150
                    )
                } else {
                    results
                }
            }
        }
    }

    // MARK: Recent searches (29)

    @ViewBuilder private var recentSearches: some View {
        let items = Array(store.recent.items.prefix(RecentSearches.shown))
        if items.isEmpty {
            Text(L10n.f("ios_search_messages_in", "Search messages in %1$@", serverName))
                .raftFont(.preview)
                .foregroundStyle(Color.raftTextTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 150)
                .transition(.opacity)
        } else {
            VStack(spacing: 0) {
                SectionHeader(title: L10n.t("ios_search_recent_title", "Recent searches"), top: 12) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { store.recent.clear() }
                    } label: {
                        Text(L10n.t("search_home_clear", "Clear"))
                            .raftFont(.footnoteStrong)
                            .foregroundStyle(Color.raftTextSecondary)
                            .contentShape(Rectangle().inset(by: -13))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.t("ios_search_clear_history", "Clear search history")))
                    .accessibilityIdentifier("search-clear-history")
                }
                RaftGroupCard {
                    ForEach(Array(items.enumerated()), id: \.element) { index, query in
                        if index > 0 { RowDivider(inset: 50) }
                        RecentSearchRow(query: query) {
                            store.searchAgain(query)
                        } remove: {
                            withAnimation(.easeOut(duration: 0.2)) { store.recent.remove(query) }
                        }
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Results (29b)

    @ViewBuilder private var results: some View {
        if store.isRelevanceFallback {
            Text(L10n.t("search_relevance_fallback_note", "Too many matches to rank by relevance, so these are sorted newest first. Try more specific words."))
                .raftFont(.footnote)
                .foregroundStyle(Color.raftTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        RaftGroupCard {
            LazyVStack(spacing: 0) {
                ForEach(Array(store.results.enumerated()), id: \.element.id) { index, result in
                    if index > 0 { RowDivider(inset: 54) }
                    resultRow(result)
                        .onAppear {
                            if index >= store.results.count - 3 { store.loadMore() }
                        }
                }
            }
        }
        .padding(.top, store.isRelevanceFallback ? 0 : 12)
        if store.isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        } else if store.loadMoreFailed {
            Button {
                store.loadMore(retrying: true)
            } label: {
                Text(L10n.t("ios_search_load_more_failed", "Couldn’t load more. Retry"))
                    .raftFont(.footnoteStrong)
                    .foregroundStyle(Color.raftTextSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-load-more-retry")
        }
    }

    private func resultRow(_ result: MessageSearchResult) -> some View {
        let persona = workspace.directory.persona(
            type: result.senderType == "agent" ? "agent" : "user",
            id: result.senderId,
            name: result.senderName,
            avatarURL: result.senderAvatarUrl
        )
        let row = MessageResultRow(result: result, persona: persona, query: store.query)
        return Button {
            open(result)
        } label: {
            row
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
        .accessibilityHint(Text(L10n.t("ios_search_open_hint", "Open in conversation")))
        .accessibilityIdentifier("search-result-\(result.id)")
    }

    // MARK: Actions

    private func cancel() {
        KeyboardDismissal.now()
        dismiss()
    }

    /// 29c: the conversation (or thread) at the message, which flashes there.
    private func open(_ result: MessageSearchResult) {
        KeyboardDismissal.now()
        store.noteOpened()
        model.push(route(for: result))
    }

    private func route(for result: MessageSearchResult) -> AppRoute {
        let list = workspace.channelList
        if result.isThreadReply, let parentMessageId = result.parentMessageId, let parentChannelId = result.parentChannelId {
            return .thread(ThreadRef(
                parentChannelId: parentChannelId,
                parentMessageId: parentMessageId,
                threadChannelId: result.channelId,
                title: list.row(id: parentChannelId)?.title ?? result.parentChannelName ?? "",
                focusMessageId: result.id
            ))
        }
        if result.isTask {
            return .conversation(ConversationRef(
                channelId: result.channelId,
                title: result.parentChannelName ?? result.channelName ?? "",
                kind: .task,
                focusMessageId: result.id,
                subtitle: result.taskSubtitle
            ))
        }
        let row = list.row(id: result.channelId)
        return .conversation(ConversationRef(
            channelId: result.channelId,
            title: row?.title ?? result.channelName ?? "",
            kind: result.isDirectMessage ? .directMessage : .channel,
            focusMessageId: result.id,
            lastReadSeq: row?.maxReadSeq
        ))
    }

    /// After a first page: "Results updated" when the count changed, or the no-match line.
    private func announceResults() {
        guard store.phase == .loaded else { return }
        if store.results.isEmpty {
            announcedCount = 0
            AccessibilityNotification.Announcement(L10n.f("ios_search_no_match", "No messages match “%1$@”", store.query)).post()
        } else if store.results.count != announcedCount {
            announcedCount = store.results.count
            AccessibilityNotification.Announcement(L10n.t("ios_search_results_updated", "Results updated")).post()
        }
    }
}

// MARK: Recent search row (29)

struct RecentSearchRow: View {
    let query: String
    let search: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: search) {
                HStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.raftTextTertiary)
                        .frame(width: 24)
                    Text(verbatim: query)
                        .raftFont(.rowTitleMedium)
                        .foregroundStyle(Color.raftTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                }
                .padding(.leading, 14)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel(Text(verbatim: query))
            .accessibilityHint(Text(L10n.t("ios_search_again_hint", "Search again")))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.raftTextTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DimOnPressButtonStyle())
            .accessibilityLabel(Text(L10n.f("search_home_remove_history", "Remove “%1$@” from search history", query)))
        }
        .transition(.opacity)
    }
}

// MARK: MessageResultRow (29b)

/// One hit: 28 avatar (no presence), author · location · time, two lines of snippet with the
/// query's words on yellow.
struct MessageResultRow: View {
    let result: MessageSearchResult
    let persona: Persona
    let query: String

    @Environment(\.colorScheme) private var scheme

    private var author: String {
        let name = result.senderName ?? ""
        return name.isEmpty ? persona.name : name
    }

    private var time: String? {
        RaftDate.parse(result.createdAt).map { MessageSearchFormat.time($0) }
    }

    /// The snippet as one line of plain text (Markdown markers dropped, newlines as spaces).
    private var snippet: String {
        let snippet = result.snippet ?? ""
        return PlainText.preview(snippet.isEmpty ? result.content : snippet)
    }

    var accessibilityLabel: String {
        let text = result.retracted ? L10n.t("ios_search_retracted", "This message was retracted.") : snippet
        let head = [author, result.location, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return "\(head). \(text)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(persona: persona, size: .compact, showsPresence: false, ringColor: .raftCard)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: author)
                        .raftFont(.author)
                        .foregroundStyle(Color.raftTextPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(verbatim: result.location)
                        .raftFont(.caption)
                        .foregroundStyle(Color.raftTextSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let time {
                        Text(verbatim: time)
                            .raftFont(.monoCaption)
                            .foregroundStyle(Color.raftTextTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(minHeight: 20)
                Group {
                    if result.retracted {
                        Text(L10n.t("ios_search_retracted", "This message was retracted."))
                            .foregroundStyle(Color.raftTextTertiary)
                    } else {
                        SearchHighlight.text(snippet, query: query)
                            .foregroundStyle(Color.raftTextPrimary)
                            .textRenderer(SearchHitRenderer(fill: Color.raftYellow.opacity(scheme == .dark ? 0.30 : 0.45)))
                    }
                }
                .raftFont(.preview)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 29e: four result-shaped rows of blocks, no shimmer.
struct MessageResultSkeleton: View {
    private static let names: [CGFloat] = [80, 64, 96, 72]
    private static let firstLines: [CGFloat] = [270, 250, 280, 240]
    private static let secondLines: [CGFloat] = [190, 210, 150, 180]

    var body: some View {
        RaftGroupCard {
            ForEach(0..<4, id: \.self) { index in
                if index > 0 { RowDivider(inset: 54) }
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.raftSkeleton)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            SkeletonBlock(width: Self.names[index], height: 14)
                            Spacer(minLength: 6)
                            SkeletonBlock(width: 34, height: 10)
                        }
                        .frame(height: 20)
                        line(Self.firstLines[index])
                        line(Self.secondLines[index])
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(height: 86, alignment: .top)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("ios_loading", "Loading")))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("search-skeleton")
    }

    /// A 10pt block, at most `width` (narrow phones shorten it).
    private func line(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.raftSkeleton)
            .frame(maxWidth: width)
            .frame(height: 10)
            .padding(.top, 6)
    }
}

// MARK: Hit highlight

/// Marks one hit of the query in a snippet (all runs of a hit share one background).
struct SearchHitAttribute: TextAttribute {
    var index: Int
}

/// Draws a rounded yellow box (radius 3, 1pt wider each side, line-high) behind each hit, then
/// the text: unlike `.backgroundColor`, the box can be rounded. Text color and weight are kept.
struct SearchHitRenderer: TextRenderer {
    var fill: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var boxes: [(index: Int, rect: CGRect)] = []
            for run in line {
                guard let hit = run[SearchHitAttribute.self] else { continue }
                let rect = run.typographicBounds.rect
                if let at = boxes.firstIndex(where: { $0.index == hit.index }) {
                    boxes[at].rect = boxes[at].rect.union(rect)
                } else {
                    boxes.append((hit.index, rect))
                }
            }
            for box in boxes {
                context.fill(Path(roundedRect: box.rect.insetBy(dx: -1, dy: 0), cornerRadius: 3, style: .continuous), with: .color(fill))
            }
            for run in line {
                context.draw(run)
            }
        }
    }
}

enum SearchHighlight {
    /// Where the query's words occur in `text` (the old client's `homeSearchHighlightRanges`):
    /// the query split on whitespace, longer words first, case ignored; overlapping or touching
    /// hits merged.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var terms: [String] = []
        for word in query.split(whereSeparator: \.isWhitespace).map(String.init)
        where !terms.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            terms.append(word)
        }
        terms.sort { $0.count > $1.count }
        var hits: [Range<String.Index>] = []
        for term in terms {
            var from = text.startIndex
            while from < text.endIndex, let hit = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex), !hit.isEmpty {
                hits.append(hit)
                from = hit.upperBound
            }
        }
        hits.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for hit in hits {
            if let last = merged.last, hit.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, hit.upperBound)
            } else {
                merged.append(hit)
            }
        }
        return merged
    }

    /// `text` with each hit marked for `SearchHitRenderer`.
    static func text(_ text: String, query: String) -> Text {
        let hits = ranges(of: query, in: text)
        guard !hits.isEmpty else { return Text(verbatim: text) }
        var parts: [Text] = []
        var cursor = text.startIndex
        for (index, hit) in hits.enumerated() {
            if cursor < hit.lowerBound {
                parts.append(Text(verbatim: String(text[cursor..<hit.lowerBound])))
            }
            parts.append(Text(verbatim: String(text[hit])).customAttribute(SearchHitAttribute(index: index)))
            cursor = hit.upperBound
        }
        if cursor < text.endIndex {
            parts.append(Text(verbatim: String(text[cursor...])))
        }
        return Text.joined(parts)
    }
}

// MARK: Formatting

enum MessageSearchFormat {
    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()

    /// Home's list time (today `HH:mm`, within 7 days `EEE`, else `MMM d`), with the year for an
    /// older message from another year.
    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days >= 7, calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            return yearFormatter.string(from: date)
        }
        return RaftFormat.listTime(date, now: now, calendar: calendar)
    }
}

extension MessageSearchResult {
    /// "in #release" / "in #ship-mobile · thread" / "in #release · task" / "Direct message".
    var location: String {
        if isDirectMessage { return L10n.t("thread_direct_message_title", "Direct message") }
        let name = "#" + (parentChannelName ?? channelName ?? "")
        if isTask { return L10n.f("ios_search_in_task", "in %1$@ · task", name) }
        if isThreadReply { return L10n.f("ios_search_in_thread", "in %1$@ · thread", name) }
        return L10n.f("ios_search_in_channel", "in %1$@", name)
    }

    /// "#12 Fix the login" under a task conversation's title.
    var taskSubtitle: String? {
        let title = PlainText.preview(taskTitle)
        switch (taskNumber, title.isEmpty) {
        case (let number?, false): return "#\(number) \(title)"
        case (let number?, true): return "#\(number)"
        case (nil, false): return title
        case (nil, true): return nil
        }
    }
}

/// Every search field (§14, §2.13 通用列宽): a white glass capsule (magnifier, field, clear), 44
/// high, and a 44 × glass circle to its right, in the page's card column (16 inside the safe
/// area, so its edges are the cards' edges). Shown in the page's own `.safeAreaBar(edge: .top)`
/// rather than `.searchable`, whose drawer has its own margins and moves the list when focused.
///
/// 29 (message search): the × closes the page and is always there. List pages (Browse, Members,
/// New message): `closeWhileFocused`, the × shows only while typing and ends the search.
struct SearchHeader: View {
    @Binding var text: String
    let prompt: String
    var focus: FocusState<Bool>.Binding
    let submit: () -> Void
    let close: () -> Void
    var closeWhileFocused = false
    var closeLabel = L10n.t("common_cancel", "Cancel")
    var fieldIdentifier = "search-field"
    /// Space above the field: 2 under a navigation bar; 12 on message search, which has no bar
    /// (so the field is 12 below the safe-area top).
    var top: CGFloat = 2
    /// A solid white field with no shadow (Browse, Members: the field sits on the page's warm
    /// canvas, where the system glass's own shadow read as a card shadow, §1.5); glass otherwise.
    var solid = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.raftTextPrimary)
                    .accessibilityHidden(true)
                TextField(text: $text, prompt: Text(verbatim: prompt).foregroundStyle(Color.raftTextTertiary)) {
                    Text(verbatim: prompt)
                }
                .font(.system(size: 17))
                .foregroundStyle(Color.raftTextPrimary)
                .focused(focus)
                .submitLabel(.search)
                .onSubmit(submit)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityAddTraits(.isSearchField)
                .accessibilityIdentifier(fieldIdentifier)
                if !text.isEmpty {
                    Button {
                        text = ""
                        focus.wrappedValue = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color(uiColor: .systemBackground), Color.raftTextPrimary)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.t("search_home_clear", "Clear")))
                    .accessibilityIdentifier("search-clear")
                }
            }
            // 12: the magnifier's ink (2 inside its frame) starts at 16 + 14 = 30, the list
            // tiles' left edge (Browse, Members).
            .padding(.leading, 12)
            .padding(.trailing, text.isEmpty ? 14 : 4)
            .frame(height: 44)
            .contentShape(Capsule())
            .onTapGesture { focus.wrappedValue = true }
            .modifier(SearchFieldSurface(solid: solid))
            if !closeWhileFocused || focus.wrappedValue {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.raftTextPrimary)
                        .frame(width: 44, height: 44)
                        .raftGlass(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: closeLabel))
                .accessibilityIdentifier("search-cancel")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: focus.wrappedValue)
        .padding(.horizontal, 16)
        .padding(.top, top)
        .padding(.bottom, 8)
    }
}

private struct SearchFieldSurface: ViewModifier {
    let solid: Bool

    func body(content: Content) -> some View {
        if solid {
            content.background(Color.raftCard, in: Capsule())
        } else {
            content.raftGlass(Capsule(), interactive: true)
        }
    }
}
