import SwiftUI

// MARK: 30 Saved

/// Saved messages (Home's Saved chip): newest saved first, swipe or long-press to remove, a tap
/// opens the message in its conversation (13.3). The first page is fetched again on every visit.
struct SavedView: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @State private var showsSkeleton = false
    @State private var retrying = false
    @State private var opening: String?
    /// The empty state is in. After the last row is removed it waits for the row's removal
    /// (~0.3s) and then fades in over 0.2s, instead of fading in under the leaving row.
    @State private var showsEmpty = false
    @State private var hadEntries = false

    private var saved: SavedStore { workspace.saved }

    private var subtitle: String? {
        guard saved.phase == .loaded, let total = saved.total, total > 0, !saved.entries.isEmpty else { return nil }
        return total == 1
            ? L10n.f("saved_count_one", "%1$d saved item", total)
            : L10n.f("saved_count", "%1$d saved items", total)
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.raftCanvas.ignoresSafeArea())
        .environment(\.defaultMinListRowHeight, 1)
        .raftNavigationTitle(L10n.t("saved_title", "Saved"), subtitle: subtitle)
        .task(id: saved.phase == .loaded && saved.entries.isEmpty) {
            let empty = saved.phase == .loaded && saved.entries.isEmpty
            guard empty else {
                showsEmpty = false
                if !saved.entries.isEmpty { hadEntries = true }
                return
            }
            if hadEntries {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                hadEntries = false
                withAnimation(.easeOut(duration: 0.2)) { showsEmpty = true }
            } else {
                showsEmpty = true
            }
        }
        .refreshable { await saved.refresh() }
        .task { await saved.refresh() }
        .task(id: saved.phase == .loading) {
            showsSkeleton = false
            guard saved.phase == .loading else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsSkeleton = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch saved.phase {
        case .idle, .loading:
            if showsSkeleton {
                SavedSkeleton().plainRow()
            }
        case .failed(let offline):
            InlineRetryRow(
                title: offline
                    ? L10n.t("ios_saved_offline", "Check your connection, then try again.")
                    : L10n.t("ios_saved_load_failed", "Couldn’t load saved messages."),
                retrying: retrying
            ) {
                retrying = true
                Task {
                    await saved.refresh()
                    retrying = false
                }
            }
            .padding(.top, 4)
            .plainRow()
        case .loaded:
            if saved.entries.isEmpty {
                if showsEmpty {
                    SavedEmptyState()
                        .transition(.opacity)
                        .plainRow()
                }
            } else {
                Color.clear.frame(height: 4).plainRow()
                ForEach(Array(saved.entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, last: index == saved.entries.count - 1)
                        .onAppear {
                            if index >= saved.entries.count - 3 { Task { await saved.loadMore() } }
                        }
                }
                footer
            }
        }
    }

    private func row(_ entry: SavedEntry, last: Bool) -> some View {
        let persona = workspace.directory.persona(
            type: entry.senderType == "agent" ? "agent" : "user",
            id: entry.senderId,
            name: entry.senderName,
            avatarURL: entry.senderAvatarUrl
        )
        let row = SavedRow(entry: entry, persona: persona, location: location(entry))
        return Button {
            Task { await open(entry) }
        } label: {
            row.overlay(alignment: .bottom) {
                if !last { RowDivider(inset: 60) }
            }
        }
        .buttonStyle(RowButtonStyle())
        .plainRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                remove(entry)
            } label: {
                Label(L10n.t("ios_saved_swipe_remove", "Remove"), systemImage: "bookmark.slash")
            }
            .tint(Color(hex: 0xC23A2B))
        }
        .contextMenu {
            Button {
                Task { await open(entry) }
            } label: {
                Label(L10n.t("ios_search_open_hint", "Open in conversation"), systemImage: "arrow.up.right")
            }
            Button {
                UIPasteboard.general.url = link(entry)
                model.showToast(L10n.t("common_copied", "Copied"))
            } label: {
                Label(L10n.t("saved_action_copy_link", "Copy link"), systemImage: "link")
            }
            Button(role: .destructive) {
                remove(entry)
            } label: {
                Label(L10n.t("saved_action_remove", "Remove from Saved"), systemImage: "bookmark.slash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
        .accessibilityHint(Text(L10n.t("ios_search_open_hint", "Open in conversation")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.t("saved_action_remove", "Remove from Saved"))) { remove(entry) }
        .accessibilityIdentifier("saved-row-\(entry.id)")
    }

    @ViewBuilder private var footer: some View {
        switch saved.more {
        case .failed:
            Button {
                Task { await saved.loadMore() }
            } label: {
                Text(L10n.t("ios_search_load_more_failed", "Couldn’t load more. Retry"))
                    .raftFont(.footnoteStrong)
                    .foregroundStyle(Color.raftTextSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .plainRow()
        case .idle, .loading:
            if saved.hasMore {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .plainRow()
                    .onAppear { Task { await saved.loadMore() } }
            }
        }
    }

    // MARK: Actions

    private func remove(_ entry: SavedEntry) {
        Task { await saved.setSaved(entry.id, false, entry: entry) }
    }

    /// 13.3: checks the message is still there (`messages/context`), then opens its conversation
    /// or thread at it; the screen there loads around it and flashes it. A message that is gone
    /// (404 / 403) is not opened: its row is removed.
    private func open(_ entry: SavedEntry) async {
        guard opening == nil else { return }
        opening = entry.id
        defer { opening = nil }
        do {
            _ = try await workspace.api.messageContext(messageId: entry.messageId, channelId: entry.channelId)
        } catch let error as APIError where error.status == 404 || error.status == 403 {
            await saved.removeUnavailable(entry.id)
            return
        } catch {
            // Offline or a server error: the conversation shows its own state.
        }
        model.push(Self.route(for: entry, list: workspace.channelList))
    }

    static func route(for entry: SavedEntry, list: ChannelListStore) -> AppRoute {
        if entry.isThreadReply, let parentMessageId = entry.parentMessageId, let parentChannelId = entry.parentChannelId {
            return .thread(ThreadRef(
                parentChannelId: parentChannelId,
                parentMessageId: parentMessageId,
                threadChannelId: entry.channelId,
                title: list.row(id: parentChannelId)?.title ?? entry.parentChannelName ?? "",
                focusMessageId: entry.messageId
            ))
        }
        if entry.isTask {
            return .conversation(ConversationRef(
                channelId: entry.channelId,
                title: entry.parentChannelName ?? entry.channelName ?? "",
                kind: .task,
                focusMessageId: entry.messageId
            ))
        }
        let row = list.row(id: entry.channelId)
        return .conversation(ConversationRef(
            channelId: entry.channelId,
            title: row?.title ?? entry.channelName ?? "",
            kind: entry.isDirectMessage ? .directMessage : .channel,
            focusMessageId: entry.messageId,
            lastReadSeq: row?.maxReadSeq
        ))
    }

    private func location(_ entry: SavedEntry) -> String {
        if entry.isDirectMessage { return L10n.t("thread_direct_message_title", "Direct message") }
        let name = "#" + ((entry.isThreadReply || entry.isTask ? entry.parentChannelName : nil) ?? entry.channelName ?? "")
        if entry.isTask { return L10n.f("ios_search_in_task", "in %1$@ · task", name) }
        if entry.isThreadReply { return L10n.f("ios_search_in_thread", "in %1$@ · thread", name) }
        return L10n.f("ios_search_in_channel", "in %1$@", name)
    }

    private func link(_ entry: SavedEntry) -> URL {
        let thread = entry.isThreadReply ? entry.parentMessageId.map { (channelId: entry.channelId, parentId: $0) } : nil
        return Permalink.message(
            base: model.environment.webURL,
            serverSlug: model.servers.selectedServer?.slug,
            channelId: thread == nil ? entry.channelId : (entry.parentChannelId ?? entry.channelId),
            isDirectMessage: entry.isDirectMessage,
            messageId: entry.messageId,
            thread: thread
        )
    }
}

// MARK: SavedRow

/// 28 avatar · author, location, time · two lines of the message · a 44 thumbnail when the
/// entry carries an image.
struct SavedRow: View {
    let entry: SavedEntry
    let persona: Persona
    let location: String

    private var author: String {
        let name = entry.senderName ?? ""
        return name.isEmpty ? persona.name : name
    }

    private var time: String? {
        RaftDate.parse(entry.createdAt).map { MessageSearchFormat.time($0) }
    }

    private var text: String { PlainText.preview(entry.content) }

    private var fileNames: String {
        entry.attachments.map(\.filename).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var thumbnail: MessageAttachment? { entry.attachments.first(where: \.isImage) }

    var accessibilityLabel: String {
        let head = [author, location, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let body = !text.isEmpty ? text : (!fileNames.isEmpty ? fileNames : L10n.t("saved_state_no_preview", "No preview"))
        return "\(head). \(body)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(persona: persona, size: .compact, showsPresence: false, ringColor: .raftCanvas)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: author)
                        .raftFont(.author)
                        .foregroundStyle(Color.raftTextPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(verbatim: location)
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
                    if !text.isEmpty {
                        Text(verbatim: text).foregroundStyle(Color.raftTextPrimary)
                    } else if !fileNames.isEmpty {
                        Text(verbatim: fileNames).foregroundStyle(Color.raftTextSecondary)
                    } else {
                        Text(L10n.t("saved_state_no_preview", "No preview")).foregroundStyle(Color.raftTextTertiary)
                    }
                }
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            // Saved entries carry no attachments (checked live), so the row runs full width (Colo 5332).
            if let thumbnail {
                SavedThumbnail(attachment: thumbnail)
                    .padding(.top, 2)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 44×44 r8, fill-cropped; `photo` when it cannot be loaded.
struct SavedThumbnail: View {
    let attachment: MessageAttachment
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            Color.raftSkeleton
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.raftTextTertiary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(shape)
        .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.18) : Color.raftInk.opacity(0.18), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: attachment.id) {
            guard let url = MessageImageLayout.thumbnailURL(attachment) else {
                failed = true
                return
            }
            if let loaded = await RaftImageCache.shared.load(url) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

// MARK: 30b Empty

struct SavedEmptyState: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "bookmark")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.raftTextTertiary)
                .padding(.bottom, 14)
            Text(L10n.t("ios_saved_empty_title", "Nothing saved yet"))
                .font(.custom(RaftFont.bold, size: 20, relativeTo: .title3))
                .foregroundStyle(Color.raftTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
            Text(L10n.t("ios_saved_empty_detail", "Long-press a message and tap Save to keep it here."))
                .raftFont(.preview)
                .foregroundStyle(Color.raftTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 146)
        .accessibilityElement(children: .combine)
    }
}

// MARK: 30c Loading

/// Five row-shaped blocks, no shimmer, dividers drawn.
struct SavedSkeleton: View {
    private static let names: [CGFloat] = [80, 64, 96, 72, 88]
    private static let firstLines: [CGFloat] = [220, 280, 270, 210, 260]
    private static let secondLines: [CGFloat] = [170, 190, 150, 180, 200]

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 4)
            ForEach(0..<5, id: \.self) { index in
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
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .padding(.vertical, 12)
                .frame(height: 86, alignment: .top)
                .overlay(alignment: .bottom) {
                    if index < 4 { RowDivider(inset: 60) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("ios_loading", "Loading")))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func line(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.raftSkeleton)
            .frame(maxWidth: width)
            .frame(height: 10)
            .padding(.top, 6)
    }
}
