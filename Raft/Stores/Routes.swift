import Foundation

enum ConversationKind: String, Hashable, Sendable {
    case channel
    case directMessage
    case thread
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
}

enum AppTab: String, Hashable, CaseIterable, Sendable {
    case home
    case activity
    case settings
}
