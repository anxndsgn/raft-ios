import Observation
import SwiftUI

/// The Join button's state on a previewed channel (§11 26): joining, failed, and the haptic
/// and announcement ticks the screen reacts to.
@MainActor
@Observable
final class ChannelJoinFlow {
    private(set) var isJoining = false
    private(set) var failed = false
    /// Joined from this screen (the "You joined" line and the member count subtitle).
    private(set) var joinedHere = false
    private(set) var tapTick = 0
    private(set) var successTick = 0
    private(set) var errorTick = 0

    func join(channelId: String, name: String, workspace: Workspace, reduceMotion: Bool) {
        guard !isJoining else { return }
        tapTick += 1
        isJoining = true
        failed = false
        Task {
            do {
                // The morph: the bar becomes the collapsed composer as the channel is marked joined.
                let animation: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86)
                try await workspace.joinChannel(channelId) { update in
                    withAnimation(animation) {
                        update()
                        isJoining = false
                    }
                }
                withAnimation(.easeOut(duration: 0.25)) { joinedHere = true }
                isJoining = false
                successTick += 1
                AccessibilityNotification.Announcement(L10n.f("ios_join_announce", "Joined %1$@", "#\(name)")).post()
            } catch {
                isJoining = false
                withAnimation(.easeOut(duration: 0.15)) { failed = true }
                errorTick += 1
                AccessibilityNotification.Announcement(L10n.t("ios_join_failed", "Couldn’t join. Try again.")).post()
            }
        }
    }

    /// The bar for `ComposerPanel` while the channel is previewed.
    func bar(channelId: String, name: String, workspace: Workspace, reduceMotion: Bool) -> ComposerJoin {
        ComposerJoin(channelName: "#\(name)", isJoining: isJoining, failed: failed) { [weak self] in
            self?.join(channelId: channelId, name: name, workspace: workspace, reduceMotion: reduceMotion)
        }
    }
}

/// 26b: "You joined #research", local and once.
struct JoinedSystemLine: View {
    let name: String

    var body: some View {
        Text(L10n.f("ios_join_system_line", "You joined %1$@", "#\(name)"))
            .raftFont(.caption)
            .foregroundStyle(Color.raftTextTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .accessibilityIdentifier("joined-system-line")
    }
}
