import SwiftUI

/// The people a screen shows and what its payloads already say about their photos.
struct AvatarNeeds: Hashable {
    /// Human user ids whose avatar the screen draws.
    var people: Set<String> = []
    /// Photos the payloads carried (reply previews, Activity rows, DM peers), by user id.
    var known: [String: String] = [:]
    /// Channels whose roster is the cheapest way to learn these people (one request each).
    var channels: [String] = []

    /// Adds a human sender (agents and system senders have no photo to look up).
    mutating func add(type: String?, id: String?, avatarURL: String? = nil) {
        guard type != "agent", type != "system", let id, !id.isEmpty else { return }
        people.insert(id)
        if let avatarURL, DirectoryStore.firstAvatar([avatarURL]) != nil { known[id] = avatarURL }
    }

    mutating func add(channel id: String?) {
        guard let id, !id.isEmpty, !channels.contains(id) else { return }
        channels.append(id)
    }
}

extension View {
    /// Settles the photos of `needs.people` while the view is shown: what the payloads carried is
    /// remembered, then the directory reads the channels' rosters and, for anyone still unknown,
    /// their member profiles (servers that hide people from the member list send no avatar with
    /// messages). Rows redraw as photos arrive; a person without one keeps the initials.
    func resolvesAvatars(_ directory: DirectoryStore, _ needs: AvatarNeeds) -> some View {
        modifier(AvatarResolver(directory: directory, needs: needs))
    }
}

private struct AvatarResolver: ViewModifier {
    let directory: DirectoryStore
    let needs: AvatarNeeds

    private struct Key: Hashable {
        var needs: AvatarNeeds
        var loaded: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: Key(needs: needs, loaded: directory.loaded)) {
            if !needs.known.isEmpty {
                directory.learn(avatars: needs.known.map { (id: $0.key, url: Optional($0.value)) })
            }
            guard !needs.people.isEmpty else { return }
            // Pages and live messages change the list in bursts: settle once they stop.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await directory.resolveAvatars(userIds: needs.people.sorted(), channelIds: needs.channels)
        }
    }
}
