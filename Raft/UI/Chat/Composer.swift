import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: Draft (§2.8)

/// What is being written in one conversation: text, picked mentions, As task, files.
@MainActor
@Observable
final class ComposerModel {
    struct DraftAttachment: Identifiable {
        enum State: Equatable {
            case uploading
            case uploaded(String)
            case failed(String)
        }

        let id = UUID()
        var filename: String
        var mimeType: String
        var data: Data
        var thumbnail: UIImage?
        var state: State

        var isImage: Bool { mimeType.hasPrefix("image/") }
    }

    var text = ""
    var mentions: [MessageMention] = []
    var asTask = false
    var attachments: [DraftAttachment] = []
    /// The highlighted picker row (hardware keyboard ↑↓).
    var highlightedMention = 0
    /// The query whose picker was closed by a tap on the stream.
    var dismissedQuery: String?

    /// `@query` being typed at the end of the text (the picker's input), if any.
    var mentionQuery: String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace || "([{".contains(before) else { return nil }
        }
        let query = text[text.index(after: at)...]
        guard !query.contains(where: \.isWhitespace), query.count <= 32 else { return nil }
        let value = String(query)
        return value == dismissedQuery ? nil : value
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSend: Bool {
        !trimmedText.isEmpty || attachments.contains { if case .failed = $0.state { false } else { true } }
    }

    var isUploading: Bool { attachments.contains { $0.state == .uploading } }
    /// Unsent text or files: keeps the composer expanded with the keyboard down.
    var hasDraft: Bool { !text.isEmpty || !attachments.isEmpty }

    /// Mentions still written in the text.
    var resolvedMentions: [MessageMention] {
        mentions.filter { text.localizedCaseInsensitiveContains("@" + $0.name) }
    }

    var uploadedIds: [String] {
        attachments.compactMap { if case .uploaded(let id) = $0.state { id } else { nil } }
    }

    /// Replaces `@query` with `@handle ` and remembers who it names.
    func pick(_ candidate: MentionCandidate) {
        guard let at = text.lastIndex(of: "@") else { return }
        text = String(text[..<at]) + "@" + candidate.handle + " "
        if !mentions.contains(where: { $0.id == candidate.id }) {
            mentions.append(MessageMention(type: candidate.type, id: candidate.id, name: candidate.handle))
        }
        highlightedMention = 0
    }

    func reset() {
        text = ""
        mentions = []
        asTask = false
        attachments = []
        highlightedMention = 0
        dismissedQuery = nil
    }

    // MARK: Uploads

    /// Adds files and uploads them at once (refused while read-only).
    func add(_ files: [UploadFile], channelId: String, api: RaftAPI, readOnly: Bool) {
        for file in files.prefix(max(0, 10 - attachments.count)) {
            let draft = DraftAttachment(
                filename: file.filename,
                mimeType: file.mimeType,
                data: file.data,
                thumbnail: file.mimeType.hasPrefix("image/") ? UIImage(data: file.data)?.preparingThumbnail(of: CGSize(width: 128, height: 128)) : nil,
                state: .uploading
            )
            attachments.append(draft)
            upload(draft.id, channelId: channelId, api: api, readOnly: readOnly)
        }
    }

    func retryUpload(_ id: UUID, channelId: String, api: RaftAPI, readOnly: Bool) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = .uploading
        upload(id, channelId: channelId, api: api, readOnly: readOnly)
    }

    func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func upload(_ id: UUID, channelId: String, api: RaftAPI, readOnly: Bool) {
        guard let draft = attachments.first(where: { $0.id == id }) else { return }
        guard !readOnly else {
            setState(id, .failed(StoreError.readOnly.errorDescription ?? ""))
            return
        }
        let file = UploadFile(filename: draft.filename, mimeType: draft.mimeType, data: draft.data)
        Task {
            do {
                let uploaded = try await api.uploadAttachments(channelId: channelId, files: [file])
                if let first = uploaded.first {
                    setState(id, .uploaded(first.id))
                } else {
                    setState(id, .failed(""))
                }
            } catch {
                setState(id, .failed(ErrorText.describe(error)))
            }
        }
    }

    private func setState(_ id: UUID, _ state: DraftAttachment.State) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = state
    }

    /// Waits until no file is uploading (Send while uploading).
    func waitForUploads() async {
        while isUploading {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

// MARK: Composer panel (§2.8)

/// The Join panel that stands in for the composer while a channel is previewed (§11 26): it
/// morphs into the collapsed composer once joined.
struct ComposerJoin {
    /// "#research".
    var channelName: String
    var isJoining = false
    var failed = false
    let join: () -> Void
}

struct ComposerPanel: View {
    enum Mode: Equatable {
        case channel(String)
        case directMessage(String)
        case thread
    }

    let mode: Mode
    @Bindable var model: ComposerModel
    var focus: FocusState<Bool>.Binding
    /// Picker rows for the current `@query` (empty: no picker).
    var candidates: [MentionCandidate] = []
    let send: () -> Void
    var pickPhotos: () -> Void = {}
    var takePhoto: () -> Void = {}
    var pickFiles: () -> Void = {}
    var retryUpload: (UUID) -> Void = { _ in }
    /// Set while the channel is previewed: the panel is the Join bar.
    var join: ComposerJoin?

    private var placeholder: String {
        switch mode {
        case .channel(let name): L10n.f("thread_composer_placeholder_channel", "Message #%1$@", name)
        case .directMessage(let name): L10n.f("thread_composer_placeholder_dm", "Message @%1$@", name)
        case .thread: L10n.t("thread_composer_placeholder_reply", "Reply in thread")
        }
    }

    /// Collapsed: a 48pt glass capsule holding only the placeholder (§2.8, XIN 5210).
    /// Expanded: the panel with tray, field and tool row (concentric with the keyboard down, r26 up).
    @State private var expanded = false
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    /// Expanded while focused, or while a draft (text or files) is waiting.
    private var wantsExpanded: Bool { focus.wrappedValue || model.hasDraft }

    var body: some View {
        GlassEffectContainer {
            panel
        }
        .onAppear {
            expanded = wantsExpanded
            #if DEBUG
            // Gallery 15 shows the expanded panel without a draft (spec still, no keyboard).
            if PreviewGallery.screen == "15" { expanded = true }
            #endif
        }
        .onChange(of: wantsExpanded) { _, target in setExpanded(target) }
        .animation(.smooth(duration: 0.25), value: model.attachments.count)
    }

    private func setExpanded(_ target: Bool) {
        guard target != expanded else { return }
        let animation: Animation = reduceMotion
            ? .easeInOut(duration: 0.2)
            : (target ? .spring(response: 0.35, dampingFraction: 0.86) : .smooth(duration: 0.25))
        withAnimation(animation) { expanded = target }
    }

    /// Starts the morph on the tap itself, together with the keyboard (the focus change
    /// lands ~0.3 s later). If focus never arrives, fall back to the collapsed capsule.
    private func expandFromTap() {
        guard !expanded else { return }
        focus.wrappedValue = true
        setExpanded(true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            if !wantsExpanded { setExpanded(false) }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let join {
                joinContent(join)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            } else {
                if expanded, !model.attachments.isEmpty {
                    AttachmentTray(model: model, retry: retryUpload)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
                field
                    // After a join the placeholder fades in as the bar settles into the capsule.
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(reduceMotion ? 0 : 0.12)),
                        removal: .opacity.animation(.easeOut(duration: 0.15))
                    ))
                if expanded {
                    toolRow
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                            removal: .opacity.animation(.easeOut(duration: 0.1))
                        ))
                }
            }
        }
        .padding(join != nil
            ? EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            : (expanded ? EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 10) : EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)))
        .frame(minHeight: 48)
        .contentShape(ComposerGlass.shape(focused: focus.wrappedValue))
        // The whole capsule is the tap target (buttons inside keep their own taps).
        .simultaneousGesture(TapGesture().onEnded { if join == nil { expandFromTap() } })
        .modifier(ComposerGlass(focused: focus.wrappedValue, namespace: glass, reduceTransparency: reduceTransparency, dark: scheme == .dark))
    }

    /// 26: "You're previewing #name" (or the failure line) over Join channel.
    private func joinContent(_ join: ComposerJoin) -> some View {
        VStack(spacing: 10) {
            Group {
                if join.failed {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 13))
                            .accessibilityHidden(true)
                        Text(L10n.t("ios_join_failed", "Couldn’t join. Try again."))
                            .font(.custom(RaftFont.semibold, size: 13, relativeTo: .footnote))
                    }
                    .foregroundStyle(Color.raftDanger)
                } else {
                    Text(L10n.f("ios_join_previewing", "You’re previewing %1$@", join.channelName))
                        .raftFont(.footnote)
                        .foregroundStyle(Color.raftTextSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            PrimaryButton(title: L10n.t("thread_action_join_channel", "Join channel"), isLoading: join.isJoining, action: join.join)
                .disabled(join.isJoining)
                .accessibilityLabel(Text(L10n.t("thread_action_join_channel", "Join channel")))
                .accessibilityHint(Text(L10n.f("ios_join_hint", "Join %1$@ to send messages", join.channelName)))
                .accessibilityValue(join.isJoining ? Text(L10n.t("ios_join_loading", "Joining")) : Text(verbatim: ""))
                .accessibilityIdentifier("join-channel")
        }
    }

    private var field: some View {
        TextField(text: $model.text, axis: .vertical) {
            Text(verbatim: placeholder).foregroundStyle(Color.raftTextTertiary)
        }
        .font(RaftFont.body.font)
        .foregroundStyle(Color.raftTextPrimary)
        .lineLimit(expanded ? 1...5 : 1...1)
        .focused(focus)
        .padding(.top, expanded ? 2 : 0)
        .padding(.bottom, expanded ? 6 : 0)
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onKeyPress(.return) {
            guard !candidates.isEmpty else { return .ignored }
            model.pick(candidates[min(model.highlightedMention, candidates.count - 1)])
            return .handled
        }
        .accessibilityHint(expanded ? Text(verbatim: "") : Text(L10n.t("ios_composer_hint", "Double-tap to write a message")))
        .accessibilityIdentifier("composer-field")
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !candidates.isEmpty else { return .ignored }
        model.highlightedMention = (model.highlightedMention + delta + candidates.count) % candidates.count
        return .handled
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            toolButton("photo", label: L10n.t("ios_attach_photo", "Photo library"), action: pickPhotos)
            if mode != .thread {
                toolButton("camera", label: L10n.t("ios_attach_camera", "Camera"), action: takePhoto)
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            }
            toolButton("paperclip", label: L10n.t("ios_attach_file", "Attach file"), action: pickFiles)
            Spacer(minLength: 8)
            if case .channel = mode {
                Button {
                    model.asTask.toggle()
                } label: {
                    HStack(spacing: 7) {
                        RaftCheckbox(isOn: model.asTask)
                        Text(L10n.t("thread_composer_as_task", "As task"))
                            .font(.custom(RaftFont.semibold, size: 14, relativeTo: .subheadline))
                            .foregroundStyle(Color.raftTextPrimary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .accessibilityAddTraits(model.asTask ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("as-task")
            }
            sendButton
        }
        .frame(height: 36)
    }

    private func toolButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbol == "photo" {
                    // SF `photo` fills its hills; the row wants three matching outlines.
                    OutlinePhotoGlyph()
                        .stroke(Color.raftTextSecondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 22, height: 18)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .regular))
                        .symbolVariant(.none)
                        .foregroundStyle(Color.raftTextSecondary)
                }
            }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .padding(.trailing, symbol == "paperclip" ? 0 : -1)
        .frame(width: 31, alignment: .leading)
        .padding(.leading, symbol == "photo" ? -4 : 0)
        .accessibilityLabel(Text(verbatim: label))
    }

    @ViewBuilder private var sendButton: some View {
        if model.canSend {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.raftInk)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.raftPink)
            .accessibilityLabel(Text(L10n.t("ios_send", "Send")))
            .accessibilityIdentifier("send-button")
            .transition(.opacity)
        } else {
            Button {} label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.raftTextDisabled)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(true)
            .accessibilityLabel(Text(L10n.t("ios_send", "Send")))
            .accessibilityIdentifier("send-button")
            .transition(.opacity)
        }
    }
}

/// One glass shape for the capsule, the expanded panel and the Join bar.
/// Keyboard down: concentric with the display corners (the bar sits 38pt from the screen's
/// left, right and bottom edges; on a 62pt-corner screen that resolves to 24, the 48pt
/// capsule's half height). Keyboard up: the r26 panel.
private struct ComposerGlass: ViewModifier {
    let focused: Bool
    let namespace: Namespace.ID
    let reduceTransparency: Bool
    let dark: Bool

    static func shape(focused: Bool) -> ConcentricRectangle {
        ConcentricRectangle(corners: focused ? .fixed(26) : .concentric, isUniform: true)
    }

    func body(content: Content) -> some View {
        let shape = Self.shape(focused: focused)
        if reduceTransparency {
            content
                .background(dark ? Color(hex: 0x2C2C29) : Color.raftCard, in: shape)
                .overlay(shape.stroke(dark ? Color.white.opacity(0.12) : Color.raftInk.opacity(0.12), lineWidth: 0.5))
        } else {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .glassEffectID("composer", in: namespace)
        }
    }
}

// MARK: Composer bar insets (§2.8)

extension View {
    /// Keyboard down: 38pt from the screen's left, right and bottom edges (whatever the
    /// device's bottom safe area), so the concentric glass shares the display's corner centre.
    /// Keyboard up: 10pt sides, 8pt above the keyboard. Driven by focus, which flips in the
    /// keyboard's own transaction, so the width change rides the keyboard animation.
    func composerBarInsets(focused: Bool) -> some View {
        modifier(ComposerBarInsets(focused: focused))
    }
}

private struct ComposerBarInsets: ViewModifier {
    let focused: Bool
    static let screenInset: CGFloat = 38

    /// The window's bottom safe area (home indicator), without the keyboard.
    private var bottomSafeArea: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, focused ? 10 : Self.screenInset)
            // The bar sits on the bottom safe area; reach down to 38pt from the physical edge.
            .padding(.bottom, focused ? 8 : Self.screenInset - bottomSafeArea)
    }
}

// MARK: Attachment tray (§3-13)

struct AttachmentTray: View {
    @Bindable var model: ComposerModel
    let retry: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.attachments) { item in
                        tile(item)
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
            }
            .scrollIndicators(.hidden)
            if model.isUploading {
                ProgressView().controlSize(.mini).tint(.raftInk)
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.raftHairline).frame(height: 0.5)
        }
        .padding(.leading, -6)
    }

    @ViewBuilder private func tile(_ item: ComposerModel.DraftAttachment) -> some View {
        Group {
            if item.isImage, let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.raftInk.opacity(0.2), lineWidth: 0.5))
                    .opacity(item.state == .uploading ? 0.8 : 1)
            } else {
                fileBlock(item)
            }
        }
        .overlay {
            if case .failed = item.state, item.isImage, item.thumbnail != nil {
                Button {
                    retry(item.id)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 16, weight: .semibold))
                        Text(L10n.t("thread_composer_attachment_upload_failed", "Upload failed"))
                            .font(.custom(RaftFont.semibold, size: 10, relativeTo: .caption2))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color.raftDanger)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.raftCard.opacity(0.85), in: .rect(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            } else if item.state == .uploading, item.isImage, item.thumbnail != nil {
                ProgressView().controlSize(.small).tint(.raftInk)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                model.remove(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color(red: 40 / 255, green: 38 / 255, blue: 36 / 255, opacity: 0.82), in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text(L10n.f("ios_remove_attachment", "Remove %1$@", item.filename)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: item.filename))
    }

    /// Non-image draft: tile + name + size. A failed upload swaps the size for a red
    /// "Upload failed" line and the whole block becomes the retry button.
    @ViewBuilder private func fileBlock(_ item: ComposerModel.DraftAttachment) -> some View {
        let failed: Bool = {
            if case .failed = item.state { return true }
            return false
        }()
        let block = HStack(spacing: 8) {
            FileTypeTile(filename: item.filename, mimeType: item.mimeType, small: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: item.filename)
                    .font(.custom(RaftFont.semibold, size: 13, relativeTo: .footnote))
                    .foregroundStyle(Color.raftTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if failed {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .semibold))
                        Text(L10n.t("thread_composer_attachment_upload_failed", "Upload failed"))
                            .font(.custom(RaftFont.semibold, size: 12, relativeTo: .caption))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.raftDanger)
                } else {
                    Text(verbatim: RaftFormat.bytes(Int64(item.data.count)))
                        .raftFont(.monoCaption)
                        .foregroundStyle(Color.raftTextTertiary)
                }
            }
            .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(TrayFill(), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(failed ? Color.raftDanger.opacity(0.5) : Color.raftInk.opacity(0.16), lineWidth: failed ? 1 : 0.5)
        )
        if failed {
            Button {
                retry(item.id)
            } label: {
                block
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(L10n.t("thread_send_failure_retry", "Retry")))
        } else {
            block
        }
    }
}

private struct TrayFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.7)
    }
}

// MARK: Mention picker (§2.9)

struct MentionPicker: View {
    let query: String
    let candidates: [MentionCandidate]
    let highlighted: Int
    let pick: (MentionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: query.isEmpty ? L10n.t("ios_mention_members", "Members") : L10n.f("ios_mention_members_matching", "Members matching “%1$@”", query))
                .font(.custom(RaftFont.semibold, size: 12, relativeTo: .caption))
                .foregroundStyle(Color.raftTextTertiary)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 6, trailing: 10))
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                Button {
                    pick(candidate)
                } label: {
                    row(candidate, selected: index == highlighted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mention-\(candidate.handle)")
            }
        }
        .padding(8)
        .raftGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row(_ candidate: MentionCandidate, selected: Bool) -> some View {
        HStack(spacing: 10) {
            AvatarView(persona: candidate.persona, size: .sm, showsPresence: candidate.isAgent, ringColor: .raftCard)
            highlightedName(candidate.name)
                .lineLimit(1)
            Text(verbatim: "@\(candidate.handle)")
                .raftFont(.monoCaption)
                .foregroundStyle(Color.raftTextTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if candidate.isAgent {
                Text(L10n.t("composer_mention_actor_agent", "Agent"))
                    .raftFont(.monoSmall)
                    .foregroundStyle(Color.raftTextSecondary)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.raftDivider, lineWidth: 1))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.raftHighlight)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.raftHighlightStroke, lineWidth: 1))
            }
        }
        .contentShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [candidate.name, candidate.isAgent ? L10n.t("member_label_agent", "Agent") : nil, "@\(candidate.handle)"].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
    }

    /// The name with the typed prefix in Bold.
    private func highlightedName(_ name: String) -> Text {
        let base = Font.custom(RaftFont.medium, size: 16, relativeTo: .body)
        let strong = Font.custom(RaftFont.bold, size: 16, relativeTo: .body)
        guard !query.isEmpty, let range = name.range(of: query, options: [.caseInsensitive, .anchored]) ?? name.range(of: " " + query, options: .caseInsensitive).map({ name.index(after: $0.lowerBound)..<$0.upperBound }) else {
            return Text(verbatim: name).font(base).foregroundStyle(Color.raftTextPrimary)
        }
        return Text(verbatim: String(name[..<range.lowerBound])).font(base).foregroundStyle(Color.raftTextPrimary)
            + Text(verbatim: String(name[range])).font(strong).foregroundStyle(Color.raftTextPrimary)
            + Text(verbatim: String(name[range.upperBound...])).font(base).foregroundStyle(Color.raftTextPrimary)
    }
}

// MARK: Pickers

/// The camera (`UIImagePickerController`).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

enum AttachmentImport {
    /// Photos picked in `PhotosPicker`, read as files.
    static func load(_ items: [PhotosPickerItem]) async -> [UploadFile] {
        var files: [UploadFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
            let ext = type.preferredFilenameExtension ?? "jpg"
            let mime = type.preferredMIMEType ?? "image/jpeg"
            files.append(UploadFile(filename: "IMG_\(Int(Date().timeIntervalSince1970))_\(index + 1).\(ext)", mimeType: mime, data: data))
        }
        return files
    }

    /// Files from `.fileImporter` (security-scoped).
    static func load(_ urls: [URL]) -> [UploadFile] {
        urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            let type = UTType(filenameExtension: url.pathExtension)
            return UploadFile(filename: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data)
        }
    }

    static func load(_ image: UIImage) -> UploadFile? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        return UploadFile(filename: "Photo_\(Int(Date().timeIntervalSince1970)).jpg", mimeType: "image/jpeg", data: data)
    }
}

// MARK: Emoji keyboard

/// A hidden text field that opens the emoji keyboard; the first emoji typed is the pick.
struct EmojiPickerField: UIViewRepresentable {
    @Binding var isActive: Bool
    let onPick: (String) -> Void

    final class Field: UITextField {
        override var textInputContextIdentifier: String? { "raft.emoji" }
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.alpha = 0.02
        field.tintColor = .clear
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if isActive, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isActive, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiPickerField
        init(_ parent: EmojiPickerField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            guard let text = field.text, let first = text.first else { return }
            field.text = ""
            guard first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }) else { return }
            parent.onPick(String(first))
            parent.isActive = false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isActive { parent.isActive = false }
        }
    }
}

/// An outline "photo": a rounded frame, a sun and two hills, stroked like SF regular at 22pt.
struct OutlinePhotoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.insetBy(dx: 0.8, dy: 0.8)
        path.addRoundedRect(in: r, cornerSize: CGSize(width: 3, height: 3), style: .continuous)
        let sun = CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.32)
        path.addEllipse(in: CGRect(x: sun.x - 1.8, y: sun.y - 1.8, width: 3.6, height: 3.6))
        path.move(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.18))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.minY + r.height * 0.55))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.56, y: r.minY + r.height * 0.74))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.6))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.12))
        return path
    }
}
