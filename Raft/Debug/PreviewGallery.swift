#if DEBUG
import SwiftUI

/// Screens with prepared data for design review: launch with `RAFT_PREVIEW=<screen>`
/// (`02`, `03`, `04`, `05`, `05b`, `06`, `06d`, `06e`, `07`, `08`, `09`, `10`, `11`, `12b`, `12c`,
/// `13`, `14`, `15`, `16`, `17`, `18`, `19`, `20`, `28`, `28b`, `28c`, `29`, `29b`, `29c`, `29d`,
/// `29e`, `30`, `30b`, `30c`, `31a`, `31`, `31c`, `31d`, `saved`). Nothing reaches a server: every
/// request fails offline.
/// `06d` / `06e` are Home (its New message and Search entries); `28*` open New message over it.
/// `12b` lifts Ruby's message into the long-press menu; `31`, `31c` and `31d` open the image
/// viewer out of 31a's first image (images are drawn locally, see `Fixtures.scenes`).
@MainActor
enum PreviewGallery {
    /// The screen being shown, for the few views that open a state on their own (alerts, drafts).
    static private(set) var screen: String?
    fileprivate static var drafts: [String: ComposerModel] = [:]
    fileprivate static var searchStore: MessageSearchStore?

    /// A prepared composer for the conversation, handed out once.
    static func takeDraft(for channelId: String) -> ComposerModel? {
        drafts.removeValue(forKey: channelId)
    }

    /// The prepared message search (29*), handed out once.
    static func takeSearchStore() -> MessageSearchStore? {
        defer { searchStore = nil }
        return searchStore
    }

    static func model(for screen: String) -> AppModel {
        self.screen = screen
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        let core = CoreServices.make(
            environment: .production,
            appInfo: .current,
            secure: InMemorySecureStore(),
            urlSession: URLSession(configuration: configuration)
        )
        let model = AppModel(core: core, preferences: .inMemory(readOnly: true), isPreview: true)
        UserDefaults.standard.set(ActivityStore.Filter.all.rawValue, forKey: "raft.activity.filter")
        Fixtures(model: model).install(screen)
        return model
    }
}

/// Fails every request as if the device were offline.
private final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

// MARK: Fixtures

@MainActor
private struct Fixtures {
    let model: AppModel

    static let me = AuthUser(id: "u-maya", email: "maya@raft.build", name: "maya", displayName: "Maya Chen")
    static let servers = [
        AuthServer(id: "s-design", name: "Raft Design", slug: "raft-design", role: "owner"),
        AuthServer(id: "s-labs", name: "Northwind Labs", slug: "northwind", role: "member"),
        AuthServer(id: "s-oss", name: "Open Source Guild", slug: "oss-guild", role: "member"),
    ]

    func install(_ screen: String) {
        switch screen {
        case "02":
            model.session.debugSet(phase: .signedOut, failure: .incorrectCredentials)
        case "03", "04":
            let challenge = SignInChallenge(token: "preview", expiresAt: nil, maskedEmail: "m***@raft.build", methodNames: ["totp", "backup_code"])
            let prompt = SecondFactorPrompt(stage: .signInChallenge(challenge), methods: [.totp, .backupCode], refusedCall: "POST auth/login")
            model.session.debugSet(phase: .secondFactor(prompt))
            model.authPath = screen == "03" ? [.totp] : [.totp, .backupCode]
        case "05":
            model.session.debugSet(phase: .signedIn, session: session(servers: Self.servers, selected: nil))
        case "05b":
            model.session.debugSet(phase: .signedIn, session: session(servers: [], selected: nil))
        default:
            signedIn(screen)
        }
    }

    private func session(servers: [AuthServer], selected: String?) -> StoredSession {
        StoredSession(
            user: Self.me,
            tokens: TokenPair(accessToken: "preview", refreshToken: "preview"),
            servers: servers,
            selectedServerId: selected,
            signedInAt: .now
        )
    }

    private func signedIn(_ screen: String) {
        model.session.debugSet(phase: .signedIn, session: session(servers: Self.servers, selected: "s-design"))
        let workspace = Workspace(serverId: "s-design", currentUserId: Self.me.id, api: model.core.api, preferences: model.preferences, realtime: nil)
        model.installPreview(workspace: workspace)
        workspace.directory.debugSeed(agents: Self.agents, members: decode([ServerMember].self, Self.members))
        workspace.homeExtras.debugSeed(
            pinned: decode([SidebarOrder.PinnedRef].self, [["kind": "channel", "id": "c-announce"], ["kind": "channel", "id": "c-now"]]),
            level: .all,
            previews: [
                "c-release": .init(sender: "Leo Park", text: "@Maya can you review the 2.4 notes before noon?"),
                "d-builder": .init(sender: "Builder", text: "Pushed the fix for the login crash, PR #486 is ready for review."),
                "c-mobile": .init(sender: "Atlas", text: "Release notes for 2.4 are drafted.", threadTitle: "Reviewed #482, approved."),
            ]
        )
        seedHome(workspace, loading: screen == "07")
        seedSaved(workspace, screen: screen)
        if screen == "08" {
            workspace.debugSet(connection: .reconnecting(after: 4, failures: 3, reason: "preview"))
        }
        switch screen {
        case "09", "11", "12b", "12c", "13", "15":
            let store = chat(workspace, failed: screen == "15")
            if screen == "11" {
                let draft = ComposerModel()
                draft.text = "@r"
                PreviewGallery.drafts[store.channelId] = draft
            }
            if screen == "13" {
                let draft = ComposerModel()
                draft.text = "Here are the new onboarding screens"
                draft.attachments = [
                    .init(filename: "store-hero.png", mimeType: "image/png", data: Data(count: 412_000), thumbnail: heroArt(), state: .uploaded("att-1")),
                    .init(filename: "store-shots.fig", mimeType: "application/octet-stream", data: Data(count: 1_240_000), thumbnail: nil, state: .uploaded("att-2")),
                    .init(filename: "flows-v3.pdf", mimeType: "application/pdf", data: Data(count: 348_000), thumbnail: nil, state: .failed("Upload failed")),
                ]
                PreviewGallery.drafts[store.channelId] = draft
            }
            model.homePath = [.conversation(ConversationRef(channelId: store.channelId, title: store.title, kind: .channel))]
        case "10":
            let store = directMessage(workspace)
            model.homePath = [.conversation(ConversationRef(channelId: store.channelId, title: store.title, kind: .directMessage))]
        case "14":
            let ref = ConversationRef(channelId: "c-launch", title: "launch-plan", kind: .channel)
            workspace.conversation(for: ref).debugSeed(phase: .loaded, messages: [])
            model.homePath = [.conversation(ref)]
        case "16":
            let ref = thread(workspace)
            model.homePath = [.conversation(ConversationRef(channelId: "c-mobile", title: "ship-mobile", kind: .channel)), .thread(ref)]
            _ = chat(workspace, failed: false)
        case "17", "18":
            workspace.activity.debugSeed(phase: .loaded, items: screen == "17" ? decode([InboxItem].self, Self.inbox) : [])
            model.tab = .activity
        case "19", "20":
            model.tab = .settings
        case "30", "30b", "30c", "saved":
            model.homePath = [.saved]
        case "31a", "31", "31c", "31d":
            let store = imageChat(workspace)
            model.homePath = [.conversation(ConversationRef(channelId: store.channelId, title: store.title, kind: .channel))]
        case "29", "29b", "29d", "29e":
            PreviewGallery.searchStore = search(screen)
            model.homePath = [.messageSearch]
        case "29c":
            PreviewGallery.searchStore = search("29b")
            _ = chat(workspace, failed: false)
            model.homePath = [
                .messageSearch,
                .conversation(ConversationRef(channelId: "c-mobile", title: "ship-mobile", kind: .channel, focusMessageId: "m4")),
            ]
        default:
            break
        }
    }

    // MARK: Search (29)

    private func search(_ screen: String) -> MessageSearchStore {
        let recent = RecentSearches(serverId: "s-design", userId: Self.me.id, defaults: nil)
        recent.debugSeed(["release notes", "settings crash", "TestFlight 2.4", "visual baselines", "PR #482"])
        let store = MessageSearchStore(api: model.core.api, recent: recent)
        switch screen {
        case "29b":
            store.debugSeed(text: "2.4 notes", phase: .loaded, results: decode([MessageSearchResult].self, Self.searchResults))
        case "29d":
            store.debugSeed(text: "xyz", phase: .loaded)
        case "29e":
            store.debugSeed(text: "2.4 notes", phase: .loading)
        default:
            break
        }
        return store
    }

    private static var searchResults: [[String: Any]] {
        func hit(
            _ id: String, _ senderId: String, _ senderType: String, _ senderName: String, channel: (id: String, name: String, type: String),
            parent: (channelId: String, name: String, type: String, messageId: String?)? = nil, minutes: Double, _ content: String
        ) -> [String: Any] {
            var value: [String: Any] = [
                "id": id, "channelId": channel.id, "channelName": channel.name, "channelType": channel.type,
                "parentChannelId": parent?.channelId ?? channel.id, "parentChannelName": parent?.name ?? channel.name,
                "parentChannelType": parent?.type ?? channel.type,
                "senderId": senderId, "senderType": senderType, "senderName": senderName,
                "content": content, "snippet": content, "createdAt": iso(minutes),
            ]
            if let messageId = parent?.messageId { value["parentMessageId"] = messageId; value["threadId"] = channel.id }
            return value
        }
        let release = (id: "c-release", name: "release", type: "channel")
        let mobile = (id: "c-mobile", name: "ship-mobile", type: "channel")
        return [
            hit("s1", "u-maya", "user", "Maya Chen", channel: release, minutes: 21,
                "Can you review the 2.4 notes before noon? Leo wants them in the TestFlight build description too."),
            hit("m4", "a-atlas", "agent", "Atlas", channel: mobile, minutes: 32,
                "Reviewed #482, approved. Release notes for 2.4 are drafted in the thread."),
            hit("r1", "a-atlas", "agent", "Atlas", channel: (id: "t-notes", name: "ship-mobile", type: "thread"),
                parent: (channelId: "c-mobile", name: "ship-mobile", type: "channel", messageId: "m4"), minutes: 31,
                "Draft is ready, 6 fixes and 2 features. Want me to post the 2.4 notes to #release when it’s approved?"),
            hit("s4", "a-nova", "agent", "Nova", channel: release, minutes: 60 * 50,
                "TestFlight 2.4.0 (317) is processing. I’ll paste the notes into the build description once it’s done."),
            hit("s5", "u-leo", "user", "Leo Park", channel: (id: "d-leo", name: "dm-leo", type: "dm"), minutes: 60 * 52,
                "Do the 2.4 notes mention the settings crash fix? Ruby’s PR should be in there."),
            hit("s6", "a-ruby", "agent", "Ruby", channel: mobile, minutes: 60 * 75,
                "Added a line about the locale crash to the 2.4 release notes draft."),
        ]
    }

    // MARK: Home

    private func seedHome(_ workspace: Workspace, loading: Bool) {
        guard !loading else {
            workspace.channelList.debugSeed(phase: .loading)
            return
        }
        let channels: [[String: Any]] = [
            channel("c-release", "release", minutes: 20, description: "Release coordination"),
            channel("c-mobile", "ship-mobile", minutes: 31, description: "Release train for the mobile app"),
            channel("c-general", "general", minutes: 50),
            channel("c-design", "design", minutes: 60 * 26),
            channel("c-ops", "ops-alerts", minutes: 60 * 50, muted: true),
            channel("c-roadmap", "roadmap", minutes: 60 * 80, type: "private"),
            channel("c-announce", "announcements", minutes: 90),
            channel("c-now", "now", minutes: 60 * 30),
            channel("c-launch", "launch-plan", minutes: 60 * 200, description: "Share specs, drafts and reviews with people and agents here."),
        ]
        let dms: [[String: Any]] = [
            dm("d-builder", agent: "a-builder", name: "Builder", minutes: 24, preview: "Pushed the fix for the login crash, PR #486 is ready for review."),
            dm("d-cindy", agent: "a-cindy", name: "Cindy", minutes: 40, preview: "Capturing visual testing baselines for 2.4"),
            dm("d-leo", user: "u-leo", name: "Leo Park", minutes: 73, preview: "Sounds good, see you at standup"),
            dm("d-nova", agent: "a-nova", name: "Nova", minutes: 60 * 26, preview: "Build 2.4.0 (318) is uploading to internal testing now."),
        ]
        workspace.channelList.debugSeed(
            phase: .loaded,
            channels: decode([Channel].self, channels),
            directMessages: decode([DirectMessageChannel].self, dms),
            unread: [
                "c-release": ScopeUnread(unreadCount: 5, hasMention: true),
                "d-builder": ScopeUnread(unreadCount: 4),
                "c-announce": ScopeUnread(unreadCount: 3),
            ]
        )
    }

    private func channel(_ id: String, _ name: String, minutes: Double, description: String? = nil, type: String = "channel", muted: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["id": id, "name": name, "type": type, "joined": true, "lastMessageAt": iso(minutes), "maxReadSeq": 100]
        if let description { value["description"] = description }
        if muted { value["activityMuted"] = true; value["notificationLevel"] = "none" }
        return value
    }

    private func dm(_ id: String, agent: String? = nil, user: String? = nil, name: String, minutes: Double, preview: String) -> [String: Any] {
        [
            "id": id, "type": "dm", "peerType": agent == nil ? "user" : "agent", "peerId": agent ?? user ?? "",
            "peerName": name.lowercased(), "peerDisplayName": name, "lastMessageAt": iso(minutes),
            "lastMessagePreview": preview, "lastMessageSenderName": name, "maxReadSeq": 100,
        ]
    }

    // MARK: Chat

    private func chat(_ workspace: Workspace, failed: Bool) -> ConversationStore {
        let store = workspace.conversation(for: ConversationRef(channelId: "c-mobile", title: "ship-mobile", kind: .channel))
        let messages: [[String: Any]] = [
            message("m1", 1, user: "u-leo", name: "Leo Park", minutes: 34, "Morning all. Code freeze for 2.4 is at noon."),
            message("m2", 2, user: "u-maya", name: "Maya Chen", minutes: 34, "@Ruby can you fix the crash on the settings screen before the 2.4 build?",
                    mentions: [["type": "agent", "id": "a-ruby", "name": "Ruby"]]),
            message("m3", 3, agent: "a-ruby", name: "Ruby", minutes: 33, "Found it: a null `locale` when the device language isn’t supported. Fix is up in PR #482, with a test, CI is green.",
                    reactions: [["emoji": "🎉", "count": 2, "reactorIds": ["u-maya", "u-leo"], "reactorNames": ["Maya Chen", "Leo Park"]],
                                ["emoji": "👍", "count": 1, "reactorIds": ["u-leo"], "reactorNames": ["Leo Park"]]]),
            message("m4", 4, agent: "a-atlas", name: "Atlas", minutes: 32, "Reviewed #482, approved. Release notes for 2.4 are drafted in the thread.",
                    thread: ["threadChannelId": "t-notes", "replyCount": 2, "unreadCount": 0]),
            message("m5", 5, agent: "a-nova", name: "Nova", minutes: 28, "Build 2.4.0 (318) is uploading to internal testing now. I’ll post the TestFlight link here when processing finishes.",
                    reactions: [["emoji": "🚀", "count": 3, "reactorIds": ["u-leo", "a-ruby", "a-atlas"], "reactorNames": ["Leo Park", "Ruby", "Atlas"]]]),
            message("m6", 6, agent: "a-nova", name: "Nova", minutes: 27, "Release notes attached for review.",
                    attachments: [["id": "att-notes", "filename": "release-notes-2.4.pdf", "mimeType": "application/pdf", "sizeBytes": 248_000]]),
        ]
        let summaries = decode([String: ThreadSummary].self, [
            "m4": [
                "threadChannelId": "t-notes", "parentMessageId": "m4", "replyCount": 2,
                "latestReplies": [
                    ["messageId": "r1", "preview": "Draft is ready, 6 fixes and 2 features.", "senderId": "a-atlas", "senderType": "agent", "senderName": "Atlas", "createdAt": iso(31)],
                    ["messageId": "r2", "preview": "Looks good, ship it.", "senderId": "u-maya", "senderType": "user", "senderName": "Maya Chen", "createdAt": iso(30)],
                ],
            ],
        ])
        var pending: [PendingSend] = []
        if failed {
            pending = [
                PendingSend(randomId: "p1", channelId: "c-mobile", content: "Thanks all, cutting the 2.4 build now", mentions: [], state: .failed("The network connection was lost."), createdAt: .now.addingTimeInterval(-60)),
            ]
        }
        store.debugSeed(phase: .loaded, messages: decode([Message].self, messages), pending: pending, threads: summaries)
        return store
    }

    private func directMessage(_ workspace: Workspace) -> ConversationStore {
        let store = workspace.conversation(for: ConversationRef(channelId: "d-cindy", title: "Cindy", kind: .directMessage))
        let messages: [[String: Any]] = [
            message("dm1", 1, user: "u-maya", name: "Maya Chen", minutes: 60 * 20, "Can you capture visual baselines for the 2.4 screens?"),
            message("dm2", 2, agent: "a-cindy", name: "Cindy", minutes: 60 * 20 - 2, "On it. I’ll run the snapshot suite on iPhone 17 and iPhone SE, light and dark."),
            message("dm3", 3, agent: "a-cindy", name: "Cindy", minutes: 45, "Baselines are captured: 184 screens, 3 differences against 2.3, all expected (new Activity tab)."),
            message("dm4", 4, user: "u-maya", name: "Maya Chen", minutes: 42, "Great, thanks! Can you attach the diff report?"),
            message("dm5", 5, agent: "a-cindy", name: "Cindy", minutes: 40, "Capturing visual testing baselines for 2.4",
                    attachments: [["id": "att-diff", "filename": "visual-diff-2.4.html", "mimeType": "text/html", "sizeBytes": 1_240_000]]),
        ]
        store.debugSeed(phase: .loaded, messages: decode([Message].self, messages), typingAgentIds: ["a-cindy"])
        return store
    }

    private func thread(_ workspace: Workspace) -> ThreadRef {
        let parent = decode(Message.self, message("m4", 4, agent: "a-atlas", name: "Atlas", minutes: 32, "Reviewed #482, approved. Release notes for 2.4 are drafted in the thread.",
                                                  thread: ["threadChannelId": "t-notes", "replyCount": 3, "unreadCount": 0]))
        let ref = ThreadRef(parentChannelId: "c-mobile", parentMessageId: "m4", threadChannelId: "t-notes", title: "ship-mobile", parent: parent)
        let replies = ConversationStore(channelId: "t-notes", kind: .thread, title: "ship-mobile", threadParentMessageId: "m4", currentUserId: Self.me.id, api: model.core.api, preferences: model.preferences)
        let messages: [[String: Any]] = [
            message("r1", 1, agent: "a-atlas", name: "Atlas", minutes: 31, "Draft is ready, 6 fixes and 2 features:\n**Fixes**: settings crash (#482), login loop, VoiceOver labels on Activity\n**Features**: Saved list, thread follow"),
            message("r2", 2, user: "u-maya", name: "Maya Chen", minutes: 30, "Looks good, ship it."),
            message("r3", 3, user: "u-leo", name: "Leo Park", minutes: 12, "Added the TestFlight note at the end 👍",
                    reactions: [["emoji": "🙏", "count": 1, "reactorIds": ["u-maya"], "reactorNames": ["Maya Chen"]]]),
        ]
        replies.debugSeed(phase: .loaded, messages: decode([Message].self, messages))
        workspace.thread(for: ref).debugSeed(parent: parent, replies: replies, following: true)
        return ref
    }

    private func message(
        _ id: String, _ seq: Int, agent: String? = nil, user: String? = nil, name: String, minutes: Double, _ content: String,
        mentions: [[String: Any]] = [], reactions: [[String: Any]] = [], attachments: [[String: Any]] = [], thread: [String: Any]? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "seq": seq, "senderType": agent == nil ? "user" : "agent", "senderId": agent ?? user ?? "",
            "senderName": name, "content": content, "createdAt": iso(minutes),
            "mentions": mentions, "reactions": reactions, "attachments": attachments,
        ]
        if let thread { value["threadSummary"] = thread }
        return value
    }

    // MARK: Activity and Saved

    private static var inbox: [[String: Any]] {
        [
            ["kind": "channel", "channelId": "c-release", "channelName": "release", "channelType": "channel",
             "lastMessagePreview": "@Maya can you review the 2.4 notes before noon?", "lastMessageSenderName": "Leo Park",
             "lastMessageSenderType": "user", "lastMessageSenderId": "u-leo", "lastMessageAt": iso(9), "unreadCount": 5, "hasMention": true],
            ["kind": "thread", "threadChannelId": "t-notes", "parentMessageId": "m4", "parentChannelId": "c-mobile", "parentChannelName": "ship-mobile",
             "parentChannelType": "channel", "parentMessagePreview": "Reviewed #482, approved.", "latestActivityPreview": "Added the TestFlight note at the end 👍",
             "latestActivitySenderName": "Leo Park", "latestActivitySenderType": "user", "latestActivitySenderId": "u-leo",
             "latestActivityAt": iso(12), "unreadCount": 1, "hasMention": false, "isFollowing": true],
            ["kind": "dm", "channelId": "d-builder", "channelType": "dm", "lastMessagePreview": "Pushed the fix for the login crash, PR #486 is ready for review.",
             "lastMessageSenderName": "Builder", "lastMessageSenderType": "agent", "lastMessageSenderId": "a-builder",
             "lastMessageAt": iso(24), "unreadCount": 4, "hasMention": false],
            ["kind": "thread", "threadChannelId": "t-copy", "parentMessageId": "m9", "parentChannelId": "c-design", "parentChannelName": "design",
             "parentChannelType": "channel", "parentMessagePreview": "Empty state copy for Activity", "latestActivityPreview": "“You’re all caught up” tested best with 5 of 6 people.",
             "latestActivitySenderName": "Atlas", "latestActivitySenderType": "agent", "latestActivitySenderId": "a-atlas",
             "latestActivityAt": iso(60 * 3), "unreadCount": 0, "hasMention": false],
            ["kind": "channel", "channelId": "c-general", "channelName": "general", "channelType": "channel",
             "lastMessagePreview": "Lunch & learn on Thursday: agent workflows", "lastMessageSenderName": "Leo Park",
             "lastMessageSenderType": "user", "lastMessageSenderId": "u-leo", "lastMessageAt": iso(60 * 26), "unreadCount": 0, "hasMention": false],
            ["kind": "dm", "channelId": "d-nova", "channelType": "dm", "lastMessagePreview": "Build 2.4.0 (318) is uploading to internal testing now.",
             "lastMessageSenderName": "Nova", "lastMessageSenderType": "agent", "lastMessageSenderId": "a-nova",
             "lastMessageAt": iso(60 * 27), "unreadCount": 0, "hasMention": false],
        ]
    }

    private static var saved: [[String: Any]] {
        [
            ["messageId": "i4", "channelId": "c-mobile", "channelName": "ship-mobile", "channelType": "channel",
             "content": "Three options for the 2.4 store hero. I like the first one best.", "senderType": "user", "senderId": "u-leo",
             "senderName": "Leo Park", "createdAt": iso(42), "savedAt": iso(10),
             "attachments": [imageAttachment("img-hero", "store-hero-a.png")]],
            ["messageId": "m3", "channelId": "c-mobile", "channelName": "ship-mobile", "channelType": "channel",
             "content": "Found it: a null `locale` when the device language isn’t supported. Fix is up in PR #482, with a test, CI is green.",
             "senderType": "agent", "senderId": "a-ruby", "senderName": "Ruby", "createdAt": iso(33), "savedAt": iso(20)],
            ["messageId": "r1", "channelId": "t-notes", "channelName": "ship-mobile", "channelType": "thread", "parentChannelId": "c-mobile",
             "parentChannelName": "ship-mobile", "parentChannelType": "channel", "parentMessageId": "m4",
             "content": "Draft is ready, 6 fixes and 2 features. Want me to post the 2.4 notes to #announcements when it’s approved?",
             "senderType": "agent", "senderId": "a-atlas", "senderName": "Atlas", "createdAt": iso(31), "savedAt": iso(25)],
            ["messageId": "x4", "channelId": "c-research", "channelName": "research", "channelType": "channel",
             "content": "Whiteboard from the onboarding synthesis. Mentions are the biggest pain point, then search.",
             "senderType": "user", "senderId": "u-sara", "senderName": "Sara Kim", "createdAt": iso(60 * 50), "savedAt": iso(60 * 49),
             "attachments": [imageAttachment("img-board", "whiteboard.png")]],
            ["messageId": "dl1", "channelId": "d-leo", "channelName": "dm-leo", "channelType": "dm",
             "content": "Code freeze checklist: bump build number, tag release/2.4, freeze strings, then ping #release.",
             "senderType": "user", "senderId": "u-leo", "senderName": "Leo Park", "createdAt": iso(60 * 75), "savedAt": iso(60 * 74)],
            ["messageId": "s4", "channelId": "c-release", "channelName": "release", "channelType": "channel",
             "content": "TestFlight 2.4.0 (317) is processing. I’ll paste the notes into the build description when it’s done.",
             "senderType": "agent", "senderId": "a-nova", "senderName": "Nova", "createdAt": iso(60 * 24 * 40), "savedAt": iso(60 * 24 * 40)],
        ]
    }

    // MARK: Saved (12b, 12c, 30)

    /// 6 on Home's chip everywhere; 12c marks Ruby's message and Nova's continued one.
    private func seedSaved(_ workspace: Workspace, screen: String) {
        switch screen {
        case "30", "saved":
            seedImages(workspace, ["img-hero", "img-board"], originals: false)
            workspace.saved.debugSeed(phase: .loaded, entries: decode([SavedEntry].self, Self.saved), total: 6)
        case "30b":
            workspace.saved.debugSeed(phase: .loaded, total: 0)
        case "30c":
            workspace.saved.debugSeed(phase: .loading, total: 6)
        case "12c":
            workspace.saved.debugSeed(phase: .idle, total: 6, savedIds: ["m3", "m6"])
        default:
            workspace.saved.debugSeed(phase: .idle, total: 6)
        }
    }

    // MARK: Images (31a, 31)

    /// Nova's one image, Cindy's six (five shown, "+1"), Leo's three (31a; the viewer opens on
    /// the first of them in 31, 31c, 31d).
    private func imageChat(_ workspace: Workspace) -> ConversationStore {
        let store = workspace.conversation(for: ConversationRef(channelId: "c-mobile", title: "ship-mobile", kind: .channel))
        let onboarding = (1...6).map { Self.imageAttachment("img-ob\($0)", "onboarding-\($0).png") }
        let hero = [
            Self.imageAttachment("img-hero", "store-hero-a.png"),
            Self.imageAttachment("img-dusk", "store-hero-b.png"),
            Self.imageAttachment("img-coral", "store-hero-c.png"),
        ]
        let messages: [[String: Any]] = [
            message("i1", 1, agent: "a-nova", name: "Nova", minutes: 58, "Simulator capture of the new Saved list on build 318.",
                    attachments: [Self.imageAttachment("img-sim", "saved-list-318.png")]),
            message("i2", 2, agent: "a-cindy", name: "Cindy", minutes: 52, "All six onboarding screens from the baseline run.", attachments: onboarding),
            message("i3", 3, user: "u-maya", name: "Maya Chen", minutes: 44, "Do we have the store art yet?"),
            message("i4", 4, user: "u-leo", name: "Leo Park", minutes: 42, "Three options for the 2.4 store hero. I like the first one best.",
                    reactions: [["emoji": "😍", "count": 2, "reactorIds": ["u-rae", "u-noor"], "reactorNames": ["Rae Okafor", "Noor Haddad"]]],
                    attachments: hero),
        ]
        let ids = ["img-sim", "img-hero", "img-dusk", "img-coral"] + (1...6).map { "img-ob\($0)" }
        seedImages(workspace, ids, originals: true)
        store.debugSeed(phase: .loaded, messages: decode([Message].self, messages))
        return store
    }

    private static func thumbnailURL(_ id: String) -> URL {
        URL(string: "https://cdn.raft.build/thumbs/preview/\(id).webp")!
    }

    /// No width / height, as the server sends them today (4:3 first image).
    private static func imageAttachment(_ id: String, _ filename: String) -> [String: Any] {
        ["id": id, "filename": filename, "mimeType": "image/png", "sizeBytes": 412_000, "thumbnailUrl": thumbnailURL(id).absoluteString]
    }

    /// Thumbnails go into the image cache behind their made-up URLs; originals (31) are written
    /// to temporary files and handed to the attachment store as if downloaded.
    private func seedImages(_ workspace: Workspace, _ ids: [String], originals: Bool) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("raft-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in ids {
            guard let scene = Self.scenes[id] else { continue }
            RaftImageCache.shared.debugSeed(sceneArt(scene, scale: 2), for: Self.thumbnailURL(id))
            guard originals else { continue }
            let file = folder.appendingPathComponent("\(id).png")
            if let data = sceneArt(scene, scale: 3).pngData() { try? data.write(to: file) }
            workspace.attachments.debugSeed(file: file, for: id)
        }
    }

    private struct Scene {
        var sky: Color
        var sun: Color
        var hill: Color
        var ground: Color
    }

    private static let scenes: [String: Scene] = {
        let cream = Color(hex: 0xFFF8EC)
        let hero = Scene(sky: .raftCyanSoft, sun: .raftYellow, hill: .raftLime, ground: .raftPink)
        let dusk = Scene(sky: .raftLavender, sun: cream, hill: .raftCyan, ground: .raftStone)
        let coral = Scene(sky: .raftChannelChip, sun: .raftRed, hill: .raftYellow, ground: .raftOrange)
        let noon = Scene(sky: Color(hex: 0xFFF0BD), sun: .raftOrange, hill: .raftLime, ground: .raftCyan)
        let mint = Scene(sky: Color(hex: 0xDDF3D0), sun: .raftYellow, hill: .raftCyan, ground: .raftLavender)
        let slate = Scene(sky: Color(hex: 0xDCE3EA), sun: cream, hill: .raftSlate, ground: .raftPink)
        return [
            "img-hero": hero, "img-dusk": dusk, "img-coral": coral, "img-board": coral, "img-sim": noon,
            "img-ob1": hero, "img-ob2": mint, "img-ob3": coral, "img-ob4": slate, "img-ob5": dusk, "img-ob6": noon,
        ]
    }()

    /// The store hero family (sky, sun, two hills, a boat) at 320×240 points.
    private func sceneArt(_ scene: Scene, scale: CGFloat) -> UIImage {
        let ink = Color.raftInk
        let size = CGSize(width: 320, height: 240)
        func hill(_ y0: CGFloat, _ y1: CGFloat, _ c0: CGPoint, _ c1: CGPoint, closed: Bool) -> Path {
            Path { p in
                p.move(to: CGPoint(x: 0, y: y0))
                p.addCurve(to: CGPoint(x: size.width, y: y1), control1: c0, control2: c1)
                if closed {
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.addLine(to: CGPoint(x: 0, y: size.height))
                    p.closeSubpath()
                }
            }
        }
        let back = (y0: CGFloat(170), y1: CGFloat(156), c0: CGPoint(x: 90, y: 120), c1: CGPoint(x: 210, y: 220))
        let front = (y0: CGFloat(204), y1: CGFloat(200), c0: CGPoint(x: 110, y: 180), c1: CGPoint(x: 220, y: 222))
        let sail = Path { p in
            p.move(to: CGPoint(x: 102, y: 80)); p.addLine(to: CGPoint(x: 102, y: 128)); p.addLine(to: CGPoint(x: 134, y: 118)); p.closeSubpath()
        }
        let renderer = ImageRenderer(content:
            ZStack(alignment: .topLeading) {
                scene.sky
                Circle().fill(scene.sun).overlay(Circle().strokeBorder(ink, lineWidth: 3.5))
                    .frame(width: 70, height: 70).offset(x: 222, y: 34)
                hill(back.y0, back.y1, back.c0, back.c1, closed: true).fill(scene.hill)
                hill(back.y0, back.y1, back.c0, back.c1, closed: false).stroke(ink, lineWidth: 3.5)
                hill(front.y0, front.y1, front.c0, front.c1, closed: true).fill(scene.ground)
                hill(front.y0, front.y1, front.c0, front.c1, closed: false).stroke(ink, lineWidth: 3.5)
                sail.fill(Color(hex: 0xFFF8EC)).overlay(sail.stroke(ink, lineWidth: 3))
                RoundedRectangle(cornerRadius: 4).fill(Color.raftOrange)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ink, lineWidth: 3))
                    .frame(width: 72, height: 20).offset(x: 70, y: 126)
            }
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = scale
        return renderer.uiImage ?? UIImage()
    }

    // MARK: People

    static let agents = [
        AgentProfile(id: "a-ruby", name: "ruby", displayName: "Ruby", avatarUrl: "pixel:robot", runtime: "claude", activity: "online"),
        AgentProfile(id: "a-atlas", name: "atlas", displayName: "Atlas", avatarUrl: "pixel:fox", runtime: "codex", activity: "online"),
        AgentProfile(id: "a-nova", name: "nova", displayName: "Nova", avatarUrl: "pixel:tv", runtime: "claude", activity: "working"),
        AgentProfile(id: "a-cindy", name: "cindy", displayName: "Cindy", avatarUrl: "pixel:boxbot", runtime: "claude", activity: "working"),
        AgentProfile(id: "a-builder", name: "builder", displayName: "Builder", avatarUrl: "pixel:terminal", runtime: "codex", activity: "online"),
    ]

    static let members: [[String: Any]] = [
        ["userId": "u-maya", "name": "maya", "displayName": "Maya Chen", "role": "owner"],
        ["userId": "u-leo", "name": "leo", "displayName": "Leo Park", "role": "member"],
        ["userId": "u-rae", "name": "rae", "displayName": "Rae Okafor", "role": "member"],
        ["userId": "u-noor", "name": "noor", "displayName": "Noor Haddad", "role": "member"],
    ]

    // MARK: Helpers

    private static func iso(_ minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
    }

    private func iso(_ minutesAgo: Double) -> String { Self.iso(minutesAgo) }

    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try RaftJSON.decode(T.self, from: data)
        } catch {
            fatalError("Preview fixture \(T.self) does not decode: \(error)")
        }
    }

    /// A real-looking picked photo for the tray (13): the store hero art (sky, sun, hills,
    /// a boat), wider than tall so the tile shows its fill-crop.
    private func heroArt() -> UIImage {
        let ink = Color.raftInk
        let renderer = ImageRenderer(content:
            ZStack(alignment: .topLeading) {
                Color(hex: 0xD7F2FE)
                Circle().fill(Color.raftYellow).overlay(Circle().strokeBorder(ink, lineWidth: 3))
                    .frame(width: 58, height: 58).offset(x: 172, y: 28)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 120))
                    p.addCurve(to: CGPoint(x: 240, y: 118), control1: CGPoint(x: 70, y: 70), control2: CGPoint(x: 150, y: 150))
                    p.addLine(to: CGPoint(x: 240, y: 160)); p.addLine(to: CGPoint(x: 0, y: 160)); p.closeSubpath()
                }
                .fill(Color.raftLime)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 120))
                    p.addCurve(to: CGPoint(x: 240, y: 118), control1: CGPoint(x: 70, y: 70), control2: CGPoint(x: 150, y: 150))
                }
                .stroke(ink, lineWidth: 3)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 140))
                    p.addCurve(to: CGPoint(x: 240, y: 136), control1: CGPoint(x: 80, y: 118), control2: CGPoint(x: 160, y: 150))
                    p.addLine(to: CGPoint(x: 240, y: 160)); p.addLine(to: CGPoint(x: 0, y: 160)); p.closeSubpath()
                }
                .fill(Color.raftPink)
                Path { p in
                    p.move(to: CGPoint(x: 72, y: 50)); p.addLine(to: CGPoint(x: 72, y: 84)); p.addLine(to: CGPoint(x: 96, y: 80)); p.closeSubpath()
                }
                .fill(Color.white).overlay(Path { p in
                    p.move(to: CGPoint(x: 72, y: 50)); p.addLine(to: CGPoint(x: 72, y: 84)); p.addLine(to: CGPoint(x: 96, y: 80)); p.closeSubpath()
                }.stroke(ink, lineWidth: 2.5))
                RoundedRectangle(cornerRadius: 3).fill(Color.raftOrange)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ink, lineWidth: 2.5))
                    .frame(width: 52, height: 14).offset(x: 52, y: 86)
            }
            .frame(width: 240, height: 160)
        )
        renderer.scale = 2
        return renderer.uiImage ?? UIImage()
    }
}
#endif
