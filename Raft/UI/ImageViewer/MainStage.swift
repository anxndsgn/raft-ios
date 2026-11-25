import SwiftUI

/// The tabs with what lies above them: the image viewer (31) and the saved-message feedback
/// (13.2). Built again with the workspace.
struct MainStage: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model
    @State private var viewer = ImageViewerModel()

    var body: some View {
        ZStack {
            MainTabView()
            ImageViewerOverlay()
        }
        .environment(workspace.saved)
        .environment(viewer)
        .savedFeedback(workspace.saved, model: model)
    }
}
