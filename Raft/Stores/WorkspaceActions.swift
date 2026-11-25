import Foundation

/// Writes the screens ask for. Each one is refused while `AppPreferences.readOnly` is on.
extension Workspace {
    /// Mark as read (Home long-press, Unread "Mark all read").
    func markRead(channelIds: [String]) async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        for id in channelIds {
            try await api.markChannelReadAll(channelId: id)
            channelList.noteLocallyReadAll(channelId: id)
        }
        activity.scheduleRefresh()
    }

    /// Activity's "Mark all read".
    func markAllActivityRead() async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        try await api.markInboxReadAll()
        await activity.load()
        await channelList.refreshUnread()
    }

    func setThreadFollow(parentMessageId: String, follow: Bool) async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        try await api.setThreadFollow(parentMessageId: parentMessageId, follow: follow)
    }

    /// Activity's swipe: a row read (`read-all` of its conversation) or unread again.
    func setActivityRow(_ item: InboxItem, read: Bool) async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        guard let scope = item.scopeChannelId else { return }
        if read {
            try await api.markChannelReadAll(channelId: scope)
            channelList.noteLocallyReadAll(channelId: scope)
        } else {
            try await api.markChannelUnread(channelId: scope)
        }
        await activity.load()
        channelList.scheduleUnreadRefresh()
    }

    /// Activity's "Mute Activity": a thread is unfollowed, a channel or DM muted.
    func muteActivity(_ item: InboxItem) async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        if item.isSubConversation, let parent = item.parentMessageId {
            try await api.setThreadFollow(parentMessageId: parent, follow: false)
        } else if let channelId = item.channelId {
            try await api.setChannelNotificationLevel(channelId: channelId, level: .none)
        }
        await activity.load()
    }

    /// Adds or removes this person's reaction on a message held outside a conversation store
    /// (a thread's parent). The new counts arrive with `message:updated`.
    func toggleReaction(_ emoji: String, on message: Message) async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        let reacted = message.reactions.contains { $0.emoji == emoji && $0.reactorIds.contains(currentUserId) }
        if reacted {
            try await api.removeReaction(messageId: message.id, emoji: emoji)
        } else {
            try await api.addReaction(messageId: message.id, emoji: emoji)
        }
    }

    // MARK: Browse channels (§11)

    /// `POST channels/{id}/join`, then the socket room; the channel moves to Home and Joined and
    /// its open preview becomes the conversation.
    /// `applying` wraps the local change (the screen animates it).
    func joinChannel(_ channelId: String, applying: (() -> Void) -> Void = { $0() }) async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        try await api.joinChannel(id: channelId)
        applying {
            channelList.noteJoined(channelId)
            endPreview(channelId: channelId)
        }
        await joinRoom(channelId)
        channelList.scheduleUnreadRefresh()
    }

    /// `POST channels/{id}/leave`, then out of the socket room; gone from Home and Unread, its
    /// conversation stores (and pending sends) dropped.
    func leaveChannel(_ channelId: String) async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        try await api.leaveChannel(id: channelId)
        await leaveRoom(channelId)
        channelList.noteLeft(channelId)
        forgetConversation(channelId: channelId)
        activity.scheduleRefresh()
    }

    /// Channel info's Mute toggle: optimistic, rolled back when the server refuses.
    func setChannelMuted(_ channelId: String, muted: Bool) async throws {
        guard !preferences.readOnly else { throw StoreError.readOnly }
        let before = channelList.channel(id: channelId)?.activityMuted ?? !muted
        channelList.setActivityMuted(channelId, muted)
        do {
            let answered = try await api.setChannelActivityMuted(channelId: channelId, muted: muted)
            channelList.setActivityMuted(channelId, answered)
        } catch {
            channelList.setActivityMuted(channelId, before)
            throw error
        }
    }

    /// The channel's members, creator first (and its member count noted).
    func channelMembers(_ channelId: String) async throws -> [ChannelMember] {
        let members = try await api.channelMembers(channelId: channelId)
        channelList.noteMemberCount(channelId, members.count)
        directory.learn(roster: members)
        return ChannelMember.ordered(members, creatorId: channelList.channel(id: channelId)?.createdById)
    }
}
