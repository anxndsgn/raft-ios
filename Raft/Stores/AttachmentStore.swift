import Foundation

/// Signed attachment URLs (`GET attachments/{id}/url`, short-lived) and downloaded copies for
/// Quick Look. One per workspace.
@MainActor
final class AttachmentStore {
    private let api: RaftAPI?
    private var urls: [String: (url: URL, fetchedAt: Date)] = [:]
    private var files: [String: URL] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(api: RaftAPI?) {
        self.api = api
    }

    /// The original file's URL, reused for five minutes.
    func url(for id: String) async throws -> URL {
        if let cached = urls[id], Date().timeIntervalSince(cached.fetchedAt) < 300 { return cached.url }
        guard let api else { throw StoreError.notReady }
        let signed = try await api.attachmentURL(id: id)
        urls[id] = (signed.url, Date())
        return signed.url
    }

    /// A local copy named like the attachment (Quick Look needs a file and uses its extension).
    func localFile(for attachment: MessageAttachment) async throws -> URL {
        if let file = files[attachment.id], FileManager.default.fileExists(atPath: file.path) { return file }
        if let task = inFlight[attachment.id] { return try await task.value }
        let remote = try await url(for: attachment.id)
        let task = Task<URL, Error> {
            let (temporary, _) = try await URLSession.shared.download(from: remote)
            let folder = FileManager.default.temporaryDirectory.appending(path: "attachments/\(attachment.id)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = attachment.filename.isEmpty ? attachment.id : attachment.filename.replacingOccurrences(of: "/", with: "_")
            let destination = folder.appending(path: name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
        inFlight[attachment.id] = task
        defer { inFlight[attachment.id] = nil }
        let file = try await task.value
        files[attachment.id] = file
        return file
    }
}
