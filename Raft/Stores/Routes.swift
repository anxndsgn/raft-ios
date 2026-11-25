import Foundation

enum ConversationKind: String, Hashable, Sendable {
    case channel
    case directMessage
    case thread
    /// A task's own conversation (`channels.type = "task"`): a flat stream under its channel,
    /// opened from Activity read-only (tasks are not part of this app yet).
    case task
}

/// Opens a channel or DM conversation.
struct ConversationRef: Hashable, Sendable {
    var channelId: String
    var title: String
    var kind: ConversationKind
    /// Scroll to (and load around) this message.
    var focusMessageId: String?
    /// Read point known when opening (the list's `maxReadSeq`): the "new" divider starts after it.
    var lastReadSeq: Int64?
    /// Under the title (a task conversation: "#1 Fix the login").
    var subtitle: String?
}

/// Opens a thread: the parent message's replies (a thread is its own channel).
struct ThreadRef: Hashable, Sendable {
    var parentChannelId: String
    var parentMessageId: String
    /// Nil until the thread exists (no reply yet).
    var threadChannelId: String?
    /// Title of the parent conversation.
    var title: String
    var focusMessageId: String?
    /// The parent when the opener holds it (from a conversation); loaded otherwise.
    var parent: Message?
}

/// Navigation destinations under a tab's `NavigationStack`.
enum AppRoute: Hashable, Sendable {
    case conversation(ConversationRef)
    case thread(ThreadRef)
    /// The server picker, pushed from Home's switcher.
    case servers
    /// Saved messages (Home's Saved chip).
    case saved
    /// Browse channels (Home's last Channels row): join or preview the server's channels.
    case browseChannels
    /// Channel info (the chat title), by channel id.
    case channelInfo(String)
    /// A channel's full member list (Channel info › Members), by channel id.
    case channelMembers(String)
    /// Message search (Home's search button, 29).
    case messageSearch
}

enum AppTab: String, Hashable, CaseIterable, Sendable {
    case home
    case activity
    case settings
}
