import SwiftUI
import UIKit

// MARK: 31 Image viewer

/// The viewer layer at the root (above the tabs, the navigation bars and the composer).
struct ImageViewerOverlay: View {
    @Environment(ImageViewerModel.self) private var viewer

    var body: some View {
        if let session = viewer.session {
            ImageViewerView(session: session)
                .id(session.id)
        }
    }
}

/// One message's images, full screen on black: zoom, page, swipe down to close, Share and Save to
/// Photos. It opens out of the tapped thumbnail and closes back into the current one.
struct ImageViewerView: View {
    let session: ImageViewerModel.Session

    @Environment(ImageViewerModel.self) private var viewer
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private enum Stage { case opening, shown, closing }

    private struct ViewerToast: Equatable {
        let serial: Int
        let success: Bool
    }

    @State private var stage: Stage = .opening
    /// The flying image is at the page's fitted frame (else at the thumbnail's).
    @State private var expanded = false
    @State private var backdrop: Double = 0
    /// Reduce Motion (or no thumbnail on screen): the viewer cross-fades instead of flying.
    @State private var fade: Double = 1
    @State private var chromeIn = false
    @State private var chromeHidden = false
    @State private var page: Int?
    @State private var zoomed = false
    @State private var drag: CGSize = .zero
    @State private var originals: [String: UIImage] = [:]
    @State private var files: [String: URL] = [:]
    @State private var unavailable: Set<String> = []
    @State private var saving = false
    @State private var toast: ViewerToast?
    @State private var toastSerial = 0
    @State private var showsDeniedAlert = false
    @State private var successTick = 0
    @State private var errorTick = 0
    @State private var screen: CGRect = .zero

    private var index: Int { min(max(page ?? session.start, 0), session.images.count - 1) }
    private var current: MessageAttachment { session.images[index] }
    private var count: Int { session.images.count }

    private var dragFade: Double { ImageViewerDismiss.fade(dy: drag.height, height: max(screen.height, 1)) }
    private var chromeVisible: Bool { chromeIn && (!chromeHidden || voiceOver) }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                images(size: proxy.size)
                    .onAppear { screen = proxy.frame(in: .global) }
                    .onChange(of: proxy.size) { screen = proxy.frame(in: .global) }
            }
            .ignoresSafeArea()
            chrome
                .opacity(chromeVisible ? dragFade : 0)
                .allowsHitTesting(chromeVisible && stage == .shown)
            toastLayer
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!chromeVisible)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .sensoryFeedback(.success, trigger: successTick)
        .sensoryFeedback(.error, trigger: errorTick)
        .alert(L10n.t("ios_photos_denied_title", "Allow Raft to save photos?"), isPresented: $showsDeniedAlert) {
            Button(L10n.t("common_cancel", "Cancel"), role: .cancel) {}
            Button(L10n.t("common_open_settings", "Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        } message: {
            Text(L10n.t("thread_image_preview_photos_permission_denied", "Allow Photos access in Settings, then try again."))
        }
        .onAppear(perform: present)
        .onChange(of: page) { _, value in
            if let value { viewer.current = value }
        }
        .task { await loadOriginals() }
    }

    // MARK: Images

    private func images(size: CGSize) -> some View {
        let local = CGRect(origin: .zero, size: size)
        return ZStack {
            Color.black.opacity(backdrop * dragFade)
            pager(size: size)
                .scaleEffect(ImageViewerDismiss.scale(dy: drag.height, height: size.height))
                .offset(drag)
                .opacity(stage == .shown ? fade : 0)
            hero(in: local)
                .opacity(stage == .shown ? 0 : fade)
                .allowsHitTesting(false)
        }
    }

    private func pager(size: CGSize) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(session.images.enumerated()), id: \.element.id) { offset, attachment in
                    pageView(attachment, offset: offset)
                        .frame(height: size.height)
                        .containerRelativeFrame(.horizontal)
                        .id(offset)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .scrollDisabled(zoomed || count < 2)
    }

    private func pageView(_ attachment: MessageAttachment, offset: Int) -> some View {
        ZoomableImageView(
            image: image(for: attachment),
            isCurrent: offset == index,
            reduceMotion: reduceMotion,
            onZoomChange: { zoomed = $0 },
            onSingleTap: toggleChrome,
            onDismissDrag: dismissDrag
        )
        .overlay {
            if unavailable.contains(attachment.id) {
                Button {
                    unavailable.remove(attachment.id)
                    Task { await loadOriginal(attachment) }
                } label: {
                    Text(L10n.t("thread_image_preview_unavailable", "Image unavailable"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .raftGlass(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .offset(y: 120)
                .accessibilityHint(Text(L10n.t("common_retry", "Retry")))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: attachment.filename.isEmpty ? L10n.t("ios_image", "Image") : attachment.filename))
        .accessibilityValue(Text(verbatim: L10n.f("image_lightbox_counter", "%1$d of %2$d", offset + 1, count)))
        .accessibilityAddTraits(.isImage)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: go(by: 1)
            case .decrement: go(by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(L10n.t("image_lightbox_next", "Next image"))) { go(by: 1) }
        .accessibilityAction(named: Text(L10n.t("image_lightbox_previous", "Previous image"))) { go(by: -1) }
    }

    /// The image that flies between the thumbnail and the page (r10 ↔ r0).
    @ViewBuilder private func hero(in local: CGRect) -> some View {
        if let image = image(for: current) {
            let rect = expanded ? draggedFrame(fitted(image, in: local), in: local) : (sourceFrame(current.id) ?? fitted(image, in: local))
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 10, style: .continuous))
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func image(for attachment: MessageAttachment) -> UIImage? {
        originals[attachment.id] ?? viewer.thumbnail(for: attachment)
    }

    private func fitted(_ image: UIImage, in local: CGRect) -> CGRect {
        ImageViewerDismiss.fitted(image.size, in: local)
    }

    /// The page's frame as the swipe-down moves and shrinks it.
    private func draggedFrame(_ rect: CGRect, in local: CGRect) -> CGRect {
        let scale = ImageViewerDismiss.scale(dy: drag.height, height: local.height)
        let width = rect.width * scale
        let height = rect.height * scale
        let midX = local.midX + (rect.midX - local.midX) * scale + drag.width
        let midY = local.midY + (rect.midY - local.midY) * scale + drag.height
        return CGRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height)
    }

    /// The thumbnail's frame in the viewer's space (nil when it was never laid out).
    private func sourceFrame(_ id: String) -> CGRect? {
        guard let frame = viewer.source(for: id), frame.width > 0 else { return nil }
        return frame.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }

    // MARK: Open and close

    private var flies: Bool {
        !reduceMotion && image(for: current) != nil && viewer.source(for: current.id) != nil
    }

    private func present() {
        page = session.start
        #if DEBUG
        if PreviewGallery.screen == "31c" { postToast(success: true) }
        if PreviewGallery.screen == "31d" { showsDeniedAlert = true }
        #endif
        if flies {
            withAnimation(.spring(duration: 0.35, bounce: 0)) {
                expanded = true
                backdrop = 1
            } completion: {
                stage = .shown
            }
        } else {
            expanded = true
            fade = 0
            stage = .shown
            withAnimation(.easeOut(duration: 0.2)) {
                fade = 1
                backdrop = 1
            }
        }
        withAnimation(.easeOut(duration: 0.2).delay(0.1)) { chromeIn = true }
    }

    private func close() {
        guard stage == .shown else { return }
        if flies && !zoomed {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { stage = .closing }
            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                expanded = false
                backdrop = 0
                chromeIn = false
                drag = .zero
            } completion: {
                viewer.dismiss()
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                fade = 0
                backdrop = 0
                chromeIn = false
            } completion: {
                viewer.dismiss()
            }
        }
    }

    private func dismissDrag(_ translation: CGSize, velocity: CGPoint, ended: Bool) {
        guard stage == .shown, !zoomed else { return }
        if !ended {
            drag = translation
        } else if ImageViewerDismiss.closes(dy: translation.height, velocityY: velocity.y) {
            close()
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { drag = .zero }
        }
    }

    private func toggleChrome() {
        guard !voiceOver else { return }
        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
    }

    private func go(by delta: Int) {
        let next = min(max(index + delta, 0), count - 1)
        guard next != index else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { page = next }
    }

    // MARK: Originals

    /// The originals, signed in one batch for the message (`attachments/urls`), the open page
    /// first; each replaces its thumbnail with a short cross-fade.
    private func loadOriginals() async {
        await session.attachments.prefetchURLs(for: session.images.map(\.id))
        let start = session.start
        let ordered = [session.images[start]] + session.images.enumerated().filter { $0.offset != start }.map(\.element)
        for attachment in ordered {
            await loadOriginal(attachment)
        }
    }

    private func loadOriginal(_ attachment: MessageAttachment) async {
        do {
            let file = try await session.attachments.localFile(for: attachment)
            files[attachment.id] = file
            let path = file.path
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let image = UIImage(contentsOfFile: path) else { return nil }
                return await image.byPreparingForDisplay() ?? image
            }.value
            if let decoded { originals[attachment.id] = decoded }
        } catch {
            unavailable.insert(attachment.id)
        }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 0) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .raftGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.t("common_close", "Close")))
                    Spacer(minLength: 8)
                    if count >= 2 {
                        Text(verbatim: L10n.f("ios_image_viewer_page", "%1$d / %2$d", index + 1, count))
                            .font(.custom(RaftFont.mono, size: 13, relativeTo: .footnote))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .raftGlass(Capsule())
                            .contentTransition(.numericText())
                            .accessibilityLabel(Text(verbatim: L10n.f("image_lightbox_counter", "%1$d of %2$d", index + 1, count)))
                    }
                    Spacer(minLength: 8)
                    shareButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            Spacer(minLength: 0)
            infoBar
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var shareButton: some View {
        let label = Text(L10n.t("common_share", "Share"))
        if let file = files[current.id] {
            ShareLink(item: file) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .raftGlass(Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        } else {
            ZStack {
                if unavailable.contains(current.id) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .frame(width: 44, height: 44)
            .raftGlass(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits([.isButton])
            .accessibilityValue(unavailable.contains(current.id) ? Text(L10n.t("thread_image_preview_unavailable", "Image unavailable")) : Text(L10n.t("ios_loading", "Loading")))
        }
    }

    private var infoBar: some View {
        HStack(spacing: 10) {
            AvatarView(persona: session.sender, size: .mini, showsPresence: false)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: session.sender.name)
                    .font(.custom(RaftFont.bold, size: 15, relativeTo: .subheadline))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let date = session.date {
                    Text(verbatim: ImageViewerFormat.time(date))
                        .raftFont(.monoCaption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            saveButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 60)
        .raftGlass(Capsule())
    }

    private var canSave: Bool {
        MessageImageLayout.isDecodable(current.mimeType) && !unavailable.contains(current.id)
    }

    private var saveButton: some View {
        Button(action: save) {
            HStack(spacing: 6) {
                if saving {
                    ProgressView().controlSize(.small).tint(.white).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 17, weight: .semibold))
                }
                Text(L10n.t("ios_image_viewer_save", "Save"))
                    .font(.custom(RaftFont.semibold, size: 15, relativeTo: .subheadline))
            }
            .foregroundStyle(.white.opacity(canSave ? 1 : 0.4))
            .padding(.leading, 13)
            .padding(.trailing, 16)
            .frame(height: 44)
            .background(Color.white.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(saving || !canSave)
        .accessibilityLabel(Text(L10n.t("thread_image_preview_save_to_photos", "Save to Photos")))
        .accessibilityValue(saving ? Text(L10n.t("thread_image_preview_saving_to_photos", "Saving to Photos…")) : Text(verbatim: ""))
        .accessibilityHint(MessageImageLayout.isDecodable(current.mimeType) ? Text(verbatim: "") : Text(L10n.t("thread_image_preview_photos_unsupported", "This attachment is not a supported image.")))
    }

    // MARK: Save to Photos (31c, 31d)

    private func save() {
        let attachment = current
        let store = session.attachments
        saving = true
        Task {
            defer { saving = false }
            switch await PhotoSaver.authorize() {
            case .denied?:
                showsDeniedAlert = true
                return
            case .restricted?:
                model.showToast(L10n.t("thread_image_preview_photos_permission_restricted", "Photos access is restricted on this device."))
                return
            case .some:
                return
            case nil:
                break
            }
            guard let file = try? await store.localFile(for: attachment) else {
                postToast(success: false)
                return
            }
            postToast(success: await PhotoSaver.save(file: file, filename: attachment.filename) == .saved)
        }
    }

    private func postToast(success: Bool) {
        toastSerial += 1
        withAnimation(.easeOut(duration: 0.2)) { toast = ViewerToast(serial: toastSerial, success: success) }
        if success {
            successTick += 1
            AccessibilityNotification.Announcement(L10n.t("thread_image_preview_saved_to_photos", "Saved to Photos")).post()
        } else {
            errorTick += 1
            AccessibilityNotification.Announcement(L10n.t("thread_image_preview_photos_save_failed", "Couldn’t save this image to Photos. Try again.")).post()
        }
    }

    private var toastLayer: some View {
        VStack {
            if let toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.success ? "checkmark" : "exclamationmark.circle")
                        .font(.system(size: 15, weight: .bold))
                    Text(toast.success
                         ? L10n.t("thread_image_preview_saved_to_photos", "Saved to Photos")
                         : L10n.t("thread_image_preview_photos_save_failed", "Couldn’t save this image to Photos. Try again."))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .frame(height: 40)
                .raftGlass(Capsule())
                .padding(.top, 62)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)), removal: .opacity))
                .id(toast.serial)
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: toast?.serial) {
            guard toast != nil else { return }
            #if DEBUG
            if PreviewGallery.screen == "31c" { return }
            #endif
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { toast = nil }
        }
    }
}
