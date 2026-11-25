import SwiftUI

// MARK: 06d entry · 28 / 28b / 28c New message

/// Someone a DM can be opened with: a server member (not me) or an agent.
struct NewMessagePerson: Identifiable, Hashable {
    var peer: DirectMessagePeer
    var name: String
    /// A person's `@handle` (their member `name`); an agent's `name` (matched, not shown).
    var handle: String?
    /// An agent's runtime display name ("Claude Code").
    var runtime: String?
    var persona: Persona

    var id: String { "\(peer.type):\(peer.id)" }
    var isAgent: Bool { peer.isAgent }

    /// 28b: the display name or handle contains the text (case and diacritics ignored).
    func matches(_ query: String) -> Bool {
        name.localizedStandardContains(query) || (handle?.localizedStandardContains(query) ?? false)
    }

    /// "Leo Park, @leo" / "Nova, agent, Claude Code, online".
    var accessibilityLabel: String {
        if isAgent {
            return [name, L10n.t("member_label_agent", "Agent"), runtime, persona.presence?.label].compactMap { $0 }.joined(separator: ", ")
        }
        return [name, handle.flatMap { $0.isEmpty ? nil : "@\($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

extension Workspace {
    /// Everyone in the server a DM can be opened with: agents (not deleted, offline ones too) and
    /// members (not me), by name.
    var newMessagePeople: [NewMessagePerson] {
        let agentRows = directory.agents.values
            .filter { !$0.isDeleted }
            .map { agent in
                NewMessagePerson(
                    peer: DirectMessagePeer(type: "agent", id: agent.id),
                    name: agent.visibleName,
                    handle: agent.name,
                    runtime: agent.runtimeName,
                    persona: .agent(id: agent.id, name: agent.visibleName, pixelKey: agent.pixelKey, presence: Presence(activity: agent.activity), runtime: agent.runtimeName)
                )
            }
        let memberRows = directory.members.values
            .filter { $0.userId != currentUserId && ($0.membershipStatus ?? "active") == "active" }
            .map { member in
                let name = [member.displayName, member.name].compactMap { $0 }.first { !$0.isEmpty } ?? member.userId
                return NewMessagePerson(
                    peer: DirectMessagePeer(type: "user", id: member.userId),
                    name: name,
                    handle: member.name.isEmpty ? nil : member.name,
                    persona: .human(id: member.userId, name: name, avatarURL: member.avatarUrl)
                )
            }
        return (agentRows + memberRows).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The peers of Home's most recent one-to-one DMs (no self-DM).
    func newMessageRecent(limit: Int = 3) -> [NewMessagePerson] {
        var result: [NewMessagePerson] = []
        for row in channelList.directMessageRows.sorted(by: HomeView.recent) {
            guard let dm = channelList.directMessages.first(where: { $0.id == row.id }),
                  dm.type == "dm", !dm.peerId.isEmpty,
                  dm.peerType == "agent" || dm.peerId != currentUserId else { continue }
            result.append(newMessagePerson(for: dm))
            if result.count == limit { break }
        }
        return result
    }

    private func newMessagePerson(for dm: DirectMessageChannel) -> NewMessagePerson {
        if dm.peerType == "agent" {
            let agent = directory.agent(dm.peerId)
            let persona = directory.persona(type: "agent", id: dm.peerId, name: dm.peerVisibleName, avatarURL: dm.peerAvatarUrl)
            return NewMessagePerson(peer: DirectMessagePeer(type: "agent", id: dm.peerId), name: persona.name, handle: agent?.name ?? dm.peerName, runtime: agent?.runtimeName, persona: persona)
        }
        let member = directory.members[dm.peerId]
        let persona = directory.persona(type: "user", id: dm.peerId, name: dm.peerVisibleName, avatarURL: dm.peerAvatarUrl)
        let handle = member?.name ?? dm.peerName
        return NewMessagePerson(peer: DirectMessagePeer(type: "user", id: dm.peerId), name: persona.name, handle: handle.isEmpty ? nil : handle, persona: persona)
    }
}

// MARK: 06d: the entry on Home's Direct messages header

/// `square.and.pencil` 16 at the right of the Direct messages header; a 44×44 target that does
/// not make the header taller.
struct NewMessageButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.raftTextSecondary)
                .frame(width: 44, height: 18, alignment: .trailing)
                .contentShape(Rectangle().size(width: 44, height: 44).offset(x: 0, y: -13))
        }
        .buttonStyle(DimOnPressButtonStyle())
        // Centered on the header's text line (the header aligns on first baselines).
        .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] + 4.5 }
        .accessibilityLabel(Text(L10n.t("ios_new_message_title", "New message")))
        .accessibilityHint(Text(L10n.t("ios_new_message_hint", "Start a direct message")))
        .accessibilityIdentifier("new-message")
    }
}

extension View {
    /// New message (28) over Home. The DM picked there is pushed on Home's stack once the sheet
    /// has gone (`onDismiss`), not while it slides down.
    func newMessageSheet(isPresented: Binding<Bool>) -> some View {
        modifier(NewMessageSheetModifier(isPresented: isPresented))
    }
}

private struct NewMessageSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model
    @State private var pending: ConversationRef?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                guard let ref = pending else { return }
                pending = nil
                model.push(.conversation(ref))
            }) {
                NewMessageSheet { ref in
                    // An answer after the sheet was swiped away opens nothing.
                    if isPresented { pending = ref }
                }
            }
            #if DEBUG
            .task {
                guard let screen = PreviewGallery.screen, ["28", "28b", "28c"].contains(screen) else { return }
                try? await Task.sleep(for: .milliseconds(600))
                isPresented = true
            }
            #endif
    }
}

// MARK: 28: the sheet

struct NewMessageSheet: View {
    /// The DM to show once the sheet is dismissed.
    let open: (ConversationRef) -> Void

    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    private enum PeoplePhase: Hashable {
        case loading
        case loaded
        case failed
    }

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Recent, as it was when the sheet opened (a DM arriving meanwhile does not reorder it).
    @State private var recentSnapshot: [NewMessagePerson]?
    @State private var phase: PeoplePhase = .loading
    @State private var showsSkeleton = false
    @State private var isRetrying = false
    /// The row whose DM is being created.
    @State private var openingId: String?
    /// The row whose DM could not be opened (its second line says so).
    @State private var failedId: String?
    @State private var selectTick = 0
    @State private var errorTick = 0
    /// The list's height that shows: under the bars, above the keyboard (28c places in it).
    @State private var visibleHeight: CGFloat = 0

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFiltering: Bool { !trimmed.isEmpty }
    private var recent: [NewMessagePerson] { recentSnapshot ?? workspace.newMessageRecent() }
    private var people: [NewMessagePerson] { workspace.newMessagePeople }
    private var matches: [NewMessagePerson] { isFiltering ? people.filter { $0.matches(trimmed) } : people }
    private var serverName: String { model.servers.selectedServer?.displayName ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    content
                    Color.clear.frame(height: 24)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            // The container is already the part inside the bars and the keyboard (its insets).
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                visibleHeight = height
            }
            // One DM at a time: the list takes no taps while one is being created.
            .allowsHitTesting(openingId == nil)
            .background(Color.raftCanvasWarm.ignoresSafeArea())
            .raftNavigationTitle(L10n.t("ios_new_message_title", "New message"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("common_cancel", "Cancel")) { dismiss() }
                        .accessibilityIdentifier("new-message-cancel")
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(L10n.t("ios_new_message_search_prompt", "Search people and agents"))
            )
            .searchFocused($searchFocused)
            .onSubmit(of: .search) {
                if isFiltering, let first = matches.first { select(first) }
            }
            .onChange(of: query) { failedId = nil }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(38)
        .presentationBackground(Color.raftCanvasWarm)
        .sensoryFeedback(.selection, trigger: selectTick)
        .sensoryFeedback(.error, trigger: errorTick)
        .task { await load() }
        .task(id: phase) {
            // The skeleton only when nothing is held and the lists take more than 300ms.
            showsSkeleton = false
            guard phase == .loading else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsSkeleton = true }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if isFiltering {
            if phase == .loaded && matches.isEmpty {
                // 28c: centred on the line a third of the way down the part that shows above
                // the keyboard (the upper third), not at a fixed offset.
                SearchEmptyBlock(
                    title: L10n.f("ios_new_message_no_match", "No one matches “%1$@”", trimmed),
                    detail: L10n.f("ios_new_message_members_only", "Only members of %1$@ are listed.", serverName),
                    top: visibleHeight > 0 ? 0 : 88
                )
                .frame(minHeight: visibleHeight > 0 ? visibleHeight * 2 / 3 : nil, alignment: .center)
                .onAppear {
                    AccessibilityNotification.Announcement(L10n.f("ios_new_message_no_match", "No one matches “%1$@”", trimmed)).post()
                }
            } else {
                SectionHeader(title: L10n.t("ios_new_message_people", "People and agents"), count: phase == .loaded ? matches.count : nil, top: 16)
                peopleCard(matches)
            }
        } else {
            let recent = self.recent
            if !recent.isEmpty {
                SectionHeader(title: L10n.t("ios_new_message_recent", "Recent"), top: 16)
                RaftGroupCard {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, person in
                        if index > 0 { RowDivider(inset: 58) }
                        row(person)
                    }
                }
            }
            SectionHeader(title: L10n.t("ios_new_message_people", "People and agents"), top: recent.isEmpty ? 16 : 20)
            peopleCard(matches)
        }
    }

    @ViewBuilder private func peopleCard(_ list: [NewMessagePerson]) -> some View {
        switch phase {
        case .loading:
            if showsSkeleton {
                RaftGroupCard { PersonSkeletonRows() }
            }
        case .failed:
            RaftGroupCard {
                SearchRetryRow(title: L10n.t("ios_new_message_load_failed", "Couldn’t load people."), isRetrying: isRetrying) { retry() }
            }
        case .loaded:
            if !list.isEmpty {
                RaftGroupCard {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, person in
                            if index > 0 { RowDivider(inset: 58) }
                            row(person)
                        }
                    }
                }
            }
        }
    }

    private func row(_ person: NewMessagePerson) -> some View {
        let opening = openingId == person.id
        let failed = failedId == person.id
        let exists = workspace.channelList.existingDirectMessage(peerType: person.peer.type, peerId: person.peer.id) != nil
        return Button {
            select(person)
        } label: {
            PersonRow(person: person, query: isFiltering ? trimmed : "", isOpening: opening, failed: failed)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(Text(verbatim: person.accessibilityLabel))
        .accessibilityValue(
            opening ? Text(L10n.t("ios_new_message_opening", "Opening"))
                : failed ? Text(L10n.t("ios_new_message_open_failed", "Couldn’t open conversation. Try again."))
                : Text(verbatim: "")
        )
        .accessibilityHint(exists
            ? Text(L10n.t("ios_new_message_open_hint", "Open conversation"))
            : Text(L10n.t("ios_new_message_start_hint", "Start conversation")))
        .accessibilityIdentifier("person-\(person.peer.id)")
    }

    // MARK: Actions

    private func load() async {
        if recentSnapshot == nil { recentSnapshot = workspace.newMessageRecent() }
        #if DEBUG
        switch PreviewGallery.screen {
        case "28b": query = "no"; searchFocused = true
        case "28c": query = "zz"; searchFocused = true
        default: break
        }
        #endif
        if workspace.directory.hasPeople { phase = .loaded }
        do {
            try await workspace.directory.reloadPeople()
            phase = .loaded
        } catch {
            // Held lists stay (offline: the cached people); none held: the error row.
            if !workspace.directory.hasPeople { phase = .failed }
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            do {
                try await workspace.directory.reloadPeople()
                phase = .loaded
            } catch {
                phase = workspace.directory.hasPeople ? .loaded : .failed
            }
            isRetrying = false
        }
    }

    /// Open the DM with `person`: Home's when there is one, else `POST channels/dm` (15s).
    private func select(_ person: NewMessagePerson) {
        guard openingId == nil else { return }
        selectTick += 1
        searchFocused = false
        KeyboardDismissal.now()
        failedId = nil
        if let dm = workspace.channelList.existingDirectMessage(peerType: person.peer.type, peerId: person.peer.id) {
            finish(dm)
            return
        }
        openingId = person.id
        Task {
            do {
                let dm = try await workspace.openDirectMessage(with: person.peer)
                openingId = nil
                finish(dm)
            } catch {
                openingId = nil
                failedId = person.id
                errorTick += 1
                AccessibilityNotification.Announcement(L10n.t("ios_new_message_open_failed", "Couldn’t open conversation. Try again.")).post()
            }
        }
    }

    private func finish(_ dm: DirectMessageChannel) {
        let row = workspace.channelList.row(id: dm.id)
        open(ConversationRef(
            channelId: dm.id,
            title: row?.title ?? dm.peerVisibleName,
            kind: .directMessage,
            lastReadSeq: row?.maxReadSeq ?? dm.maxReadSeq
        ))
        dismiss()
    }
}

// MARK: PersonRow (28 / 28b)

/// A person or agent: 32 avatar (an agent's presence light), name, then `@handle` or runtime +
/// Agent tag. While opening a spinner trails; after a failure line 2 says so in red.
struct PersonRow: View {
    let person: NewMessagePerson
    /// 28b: the typed text, drawn Bold where the name contains it.
    var query = ""
    var isOpening = false
    var failed = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(persona: person.persona, size: .row, showsPresence: person.isAgent, ringColor: .raftCard)
            VStack(alignment: .leading, spacing: 0) {
                name
                    .lineLimit(1)
                secondLine
                    .frame(minHeight: 16, alignment: .leading)
            }
            Spacer(minLength: 8)
            if isOpening {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    /// The name, its matching part in Bold (28b).
    private var name: Text {
        let token = RaftFont.rowTitleMedium
        let regular = token.font
        let strong = Font.custom(RaftFont.bold, size: token.size, relativeTo: token.relativeTo)
        guard !query.isEmpty, let range = person.name.localizedStandardRange(of: query) else {
            return Text(verbatim: person.name).font(regular).foregroundStyle(Color.raftTextPrimary)
        }
        return Text.joined([
            Text(verbatim: String(person.name[..<range.lowerBound])).font(regular),
            Text(verbatim: String(person.name[range])).font(strong),
            Text(verbatim: String(person.name[range.upperBound...])).font(regular),
        ])
        .foregroundStyle(Color.raftTextPrimary)
    }

    @ViewBuilder private var secondLine: some View {
        if failed {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13))
                Text(L10n.t("ios_new_message_open_failed", "Couldn’t open conversation. Try again."))
                    .font(.custom(RaftFont.semibold, size: 13, relativeTo: .footnote))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.raftDanger)
        } else if person.isAgent {
            HStack(spacing: 6) {
                if let runtime = person.runtime {
                    Text(verbatim: runtime)
                        .raftFont(.caption)
                        .foregroundStyle(Color.raftTextTertiary)
                        .lineLimit(1)
                }
                PersonAgentTag()
            }
        } else if let handle = person.handle {
            Text(verbatim: "@\(handle)")
                .raftFont(.monoCaption)
                .foregroundStyle(Color.raftTextTertiary)
                .lineLimit(1)
        }
    }
}

/// 28 loading: six rows of blocks, no shimmer.
struct PersonSkeletonRows: View {
    private static let widths: [CGFloat] = [90, 70, 110, 84, 96, 64]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.widths.enumerated()), id: \.offset) { index, width in
                if index > 0 { RowDivider(inset: 58) }
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.raftSkeleton)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: width, height: 14)
                        SkeletonBlock(width: 56, height: 10)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("ios_loading", "Loading")))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("new-message-skeleton")
    }
}
