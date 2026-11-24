import SwiftUI

// MARK: 06b Server switcher

/// The popover under Home's server capsule (and Settings' Server row): the servers, then
/// "Switch or create server" (05). Invite is out of v1's scope (§10.2), so it is not shown.
struct ServerSwitcher: View {
    @Binding var isPresented: Bool
    /// "Switch or create server": pushes the server list on the current tab.
    var onShowAll: (() -> Void)?
    @Environment(AppModel.self) private var model
    @State private var selectionTick = 0

    private var servers: [AuthServer] {
        model.servers.servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(servers) { server in
                    Button {
                        selectionTick += 1
                        isPresented = false
                        Task { await model.selectServer(server.id) }
                    } label: {
                        row(server)
                    }
                    .buttonStyle(SwitcherRowStyle(radius: 18))
                    .accessibilityIdentifier("switcher-server-\(server.name)")
                }
                Rectangle()
                    .fill(Color.raftHairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Button {
                    isPresented = false
                    if let onShowAll {
                        onShowAll()
                    } else {
                        model.push(.servers)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.raftTextSecondary)
                            .frame(width: 35)
                        Text(L10n.t("home_server_switcher_switch_or_create", "Switch or create server"))
                            .raftFont(.rowTitleMedium)
                            .foregroundStyle(Color.raftTextPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SwitcherRowStyle(radius: 16))
                .accessibilityIdentifier("switcher-all-servers")
            }
            .padding(8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 330)
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sensoryFeedback(.selection, trigger: selectionTick)
    }

    private func row(_ server: AuthServer) -> some View {
        let selected = server.id == model.servers.selectedServerId
        return HStack(spacing: 12) {
            ServerAvatar(name: server.name, side: 35)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: server.name)
                    .font(.custom(RaftFont.semibold, size: 16, relativeTo: .body))
                    .foregroundStyle(Color.raftTextPrimary)
                    .lineLimit(1)
                if let slug = server.slug, !slug.isEmpty {
                    Text(verbatim: "/\(slug)")
                        .raftFont(.monoCaption)
                        .foregroundStyle(Color.raftTextTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if selected { SelectionMark() }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 56)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.raftHighlight)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.raftHighlightStroke, lineWidth: 1))
            }
        }
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: server.name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Pressed switcher rows tint like list rows, inside their rounded shape.
private struct SwitcherRowStyle: ButtonStyle {
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? Color.raftTextPrimary.opacity(0.06) : Color.clear)
            )
    }
}
