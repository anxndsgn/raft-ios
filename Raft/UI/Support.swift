import SafariServices
import SwiftUI

/// `SFSafariViewController` in a sheet (terms, password reset, web settings).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Color.raftInk)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension View {
    /// Presents `url` in Safari when set.
    func safariSheet(_ url: Binding<URL?>) -> some View {
        sheet(item: url) { value in
            SafariView(url: value).ignoresSafeArea()
        }
    }

    /// The inline title of a pushed or root screen (§2.12): custom principal item plus a plain
    /// title for VoiceOver and the back menu.
    func raftNavigationTitle(_ title: String, hashPrefix: Bool = false, subtitle: String? = nil) -> some View {
        navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    NavTitle(title: title, hashPrefix: hashPrefix, subtitle: subtitle)
                }
            }
    }
}

/// The "Copied" pill (§3-12).
struct ToastPill: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .raftFont(.grotesk(RaftFont.semibold, 14, relativeTo: .subheadline))
            .foregroundStyle(Color.raftTextPrimary)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .raftGlass(Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

/// A text link: SemiBold 15, optional underline, padded to a 44pt target.
struct LinkButton: View {
    let title: String
    var underline = true
    var weak = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(weak ? .custom(RaftFont.medium, size: 14, relativeTo: .subheadline) : RaftFont.link.font)
                .underline(underline, color: Color.raftTextPrimary)
                .baselineOffset(0)
                .foregroundStyle(weak ? Color.raftTextSecondary : Color.raftTextPrimary)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The centered destructive text button (Sign out).
struct DangerTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .raftFont(.grotesk(RaftFont.semibold, 16, relativeTo: .body))
                .foregroundStyle(Color.raftDanger)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum Masking {
    /// `m***@raft.build`.
    static func email(_ value: String?) -> String? {
        guard let value, let at = value.firstIndex(of: "@"), at > value.startIndex else { return value }
        if value[value.index(after: value.startIndex)..<at].allSatisfy({ $0 == "*" }) { return value }
        return String(value[value.startIndex]) + "***" + value[at...]
    }
}

extension Text {
    /// `format` (one `%1$@`) with the argument in a stronger style.
    static func emphasized(_ format: String, _ argument: String, base: RaftFont, strongFont: String, strongColor: Color) -> Text {
        let parts = format.components(separatedBy: "%1$@")
        guard parts.count == 2 else { return Text(verbatim: String(format: format, argument)) }
        return Text(verbatim: parts[0]).raftStyle(base)
            + Text(verbatim: argument).font(.custom(strongFont, size: base.size, relativeTo: base.relativeTo)).foregroundStyle(strongColor)
            + Text(verbatim: parts[1]).raftStyle(base)
    }
}
