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

    /// Signed URLs for several attachments at once (`POST attachments/urls`, 50 ids per call;
    /// its items carry no `expiresAt`, so they are kept for the same five minutes). Ids the batch
    /// leaves out are asked one by one.
    @discardableResult
    func prefetchURLs(for ids: [String]) async -> [String: URL] {
        var result: [String: URL] = [:]
        var missing: [String] = []
        for id in ids {
            if let cached = urls[id], Date().timeIntervalSince(cached.fetchedAt) < 300 {
                result[id] = cached.url
            } else if !missing.contains(id) {
                missing.append(id)
            }
        }
        guard let api, !missing.isEmpty else { return result }
        for start in stride(from: 0, to: missing.count, by: 50) {
            let chunk = Array(missing[start..<min(start + 50, missing.count)])
            guard let batch = try? await api.attachmentURLs(ids: chunk) else { continue }
            for item in batch {
                guard let id = item.id, chunk.contains(id) else { continue }
                urls[id] = (item.url, Date())
                result[id] = item.url
            }
        }
        for id in missing where result[id] == nil {
            if let url = try? await url(for: id) { result[id] = url }
        }
        return result
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

    #if DEBUG
    /// Preview gallery: a local file stands in for the download.
    func debugSeed(file: URL, for id: String) {
        files[id] = file
    }
    #endif
}
