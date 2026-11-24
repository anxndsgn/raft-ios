import SwiftUI

@main
struct RaftApp: App {
    @State private var model: AppModel

    init() {
        RaftFonts.applyAppearance()
        #if DEBUG
        if let screen = ProcessInfo.processInfo.environment["RAFT_PREVIEW"], !screen.isEmpty {
            _model = State(initialValue: PreviewGallery.model(for: screen))
            return
        }
        #endif
        _model = State(initialValue: AppModel.live())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
