#if DEBUG
import SwiftUI

/// Screens with prepared data for design review (`RAFT_PREVIEW=<screen>` at launch).
@MainActor
enum PreviewGallery {
    static func model(for screen: String) -> AppModel {
        let core = CoreServices.make(environment: .production, appInfo: .current, secure: InMemorySecureStore())
        return AppModel(core: core, preferences: .inMemory(readOnly: true), isPreview: true)
    }
}
#endif
