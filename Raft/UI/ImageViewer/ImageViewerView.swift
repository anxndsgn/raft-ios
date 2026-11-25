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
        enum Kind { case saved, failed, restricted }
        let serial: Int
        let kind: Kind
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
    /// The close's flight: where the image was when it began, the backdrop's opacity then, and
    /// the progress (0 → 1) one spring drives for both. The end is the thumbnail's live frame.
    @State private var closeFrom: CGRect?
    @State private var closeBackdrop: Double = 1
    @State private var closeProgress: Double = 0

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
        // 31d: the system alert, dark like the viewer under it. A SwiftUI `.alert` here takes the
        // window's (light) style, since the viewer is a layer of the root view, not its own
        // presentation; this one is presented with a dark style of its own.
        .background {
            DarkAlertPresenter(
                isPresented: $showsDeniedAlert,
                title: L10n.t("ios_photos_denied_title", "Allow Raft to save photos?"),
                message: L10n.t("thread_image_preview_photos_permission_denied", "Allow Photos access in Settings, then try again."),
                cancel: L10n.t("common_cancel", "Cancel"),
                action: L10n.t("common_open_settings", "Open Settings")
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
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
            Color.black.opacity(stage == .closing ? closeBackdrop * (1 - closeProgress) : backdrop * dragFade)
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
        if stage == .closing, let from = closeFrom, let image = image(for: current) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .modifier(HeroFlight(from: from, to: sourceFrame(current.id) ?? from, progress: closeProgress))
        } else if let image = image(for: current) {
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
        if PreviewGallery.screen == "31c" { postToast(.saved) }
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
        if flies && !zoomed, let image = image(for: current) {
            // One spring (0.3s, no bounce) drives the image from where it is (dragged or not) to
            // the thumbnail and the backdrop from what it shows to clear. The thumbnail's frame is
            // read live, so a conversation that moves under the viewer is followed without the
            // spring retargeting (which overshot), and the backdrop no longer mixes the drag's
            // fade coming back with its own going out (which held it grey).
            let local = CGRect(origin: .zero, size: screen.size)
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                closeFrom = draggedFrame(fitted(image, in: local), in: local)
                closeBackdrop = backdrop * dragFade
                closeProgress = 0
                stage = .closing
            }
            withAnimation(.spring(duration: 0.3, bounce: 0), completionCriteria: .logicallyComplete) {
                closeProgress = 1
                chromeIn = false
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
            drag = translation
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
                postToast(.restricted)
                return
            case .some:
                return
            case nil:
                break
            }
            guard let file = try? await store.localFile(for: attachment) else {
                postToast(.failed)
                return
            }
            postToast(await PhotoSaver.save(file: file, filename: attachment.filename) == .saved ? .saved : .failed)
        }
    }

    /// The viewer's own (dark glass) toast, 31c: saved, failed, or Photos restricted.
    private func postToast(_ kind: ViewerToast.Kind) {
        toastSerial += 1
        withAnimation(.easeOut(duration: 0.2)) { toast = ViewerToast(serial: toastSerial, kind: kind) }
        switch kind {
        case .saved: successTick += 1
        case .failed: errorTick += 1
        case .restricted: break
        }
        AccessibilityNotification.Announcement(Self.toastText(kind)).post()
    }

    private static func toastText(_ kind: ViewerToast.Kind) -> String {
        switch kind {
        case .saved: L10n.t("thread_image_preview_saved_to_photos", "Saved to Photos")
        case .failed: L10n.t("thread_image_preview_photos_save_failed", "Couldn’t save this image to Photos. Try again.")
        case .restricted: L10n.t("thread_image_preview_photos_permission_restricted", "Photos access is restricted on this device.")
        }
    }

    private var toastLayer: some View {
        VStack {
            if let toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.kind == .saved ? "checkmark" : "exclamationmark.circle")
                        .font(.system(size: 15, weight: .bold))
                    Text(verbatim: Self.toastText(toast.kind))
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

/// The close's flight (31): the image between where the close began and the thumbnail, driven by
/// one animated progress. Only the progress animates, so a moving end is followed, not sprung to.
private struct HeroFlight: ViewModifier, @MainActor Animatable {
    var from: CGRect
    var to: CGRect
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = CGFloat(progress)
        let rect = CGRect(
            x: from.minX + (to.minX - from.minX) * t,
            y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
        content
            .frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .clipShape(RoundedRectangle(cornerRadius: 10 * t, style: .continuous))
            .position(x: rect.midX, y: rect.midY)
    }
}

/// A system alert with a dark style of its own (31d), presented from the view's place in the
/// hierarchy: the rest of the app keeps its appearance.
struct DarkAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let cancel: String
    let action: String
    let perform: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, context.coordinator.alert == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = .dark
        alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in context.coordinator.finish() })
        alert.addAction(UIAlertAction(title: action, style: .default) { _ in
            context.coordinator.finish()
            context.coordinator.parent.perform()
        })
        context.coordinator.alert = alert
        DispatchQueue.main.async {
            guard controller.view.window != nil else {
                context.coordinator.finish()
                return
            }
            var presenter: UIViewController = controller
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(alert, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator {
        var parent: DarkAlertPresenter
        var alert: UIAlertController?

        init(parent: DarkAlertPresenter) { self.parent = parent }

        func finish() {
            alert = nil
            parent.isPresented = false
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.alert?.dismiss(animated: false)
    }
}
