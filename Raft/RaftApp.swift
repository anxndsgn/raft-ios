import SwiftUI

@main
struct RaftApp: App {
    @State private var model: AppModel

    init() {
        AirCrashReports.start(apiKey: FeedbackConfig.appKey, endpoint: "https://apps.air.build/v1/ingest/crashes", teamID: FeedbackConfig.teamID)
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
