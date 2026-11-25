import Photos
import UIKit

/// Save to Photos (31c) with add-only access: the original file is written as it is (GIF and
/// HEIC are not converted), under its own filename.
enum PhotoSaver {
    enum Outcome: Equatable {
        case saved
        case failed
        /// Access was refused before (31d: the Settings alert).
        case denied
        /// Parental controls or a profile block it.
        case restricted
        /// The person just said no in the system prompt: nothing more is shown.
        case declined
    }

    /// Asks for access when not asked yet; nil when saving may go ahead.
    static func authorize() async -> Outcome? {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if status != .authorized && status != .limited { return .declined }
        }
        switch status {
        case .authorized, .limited: return nil
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .declined
        }
    }

    static func save(file: URL, filename: String) async -> Outcome {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                if !filename.isEmpty { options.originalFilename = filename }
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: options)
            }
            return .saved
        } catch {
            return .failed
        }
    }
}
