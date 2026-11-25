import Foundation

/// `POST channels/saved/check` → `{ savedIds }`: which of the asked ids this person saved.
struct SavedCheck: Sendable, Hashable, Decodable {
    var savedIds: [String]

    private enum CodingKeys: String, CodingKey { case savedIds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedIds = c.lenientArray(.savedIds, of: String.self).filter { !$0.isEmpty }
    }
}

/// Saved messages (server `routes/channels.ts`, v1.33.1). No realtime event reports a save made
/// elsewhere: the screens check again when they load.
extension RaftAPI {
    /// The server refuses more than 200 ids per check (`message_ids_too_many`).
    static let savedCheckLimit = 200

    /// `POST channels/saved { messageId }`. A 409 (already saved) is the state asked for.
    func saveMessage(id: String) async throws {
        do {
            _ = try await client.send(.json("POST", "channels/saved", body: ["messageId": id]))
        } catch let error as APIError where error.status == 409 {
            return
        }
    }

    /// `DELETE channels/saved/{messageId}`. A 404 (not saved) is the state asked for.
    func unsaveMessage(id: String) async throws {
        do {
            _ = try await client.send(.delete("channels/saved/\(Self.segment(id))"))
        } catch let error as APIError where error.status == 404 {
            return
        }
    }

    /// `POST channels/saved/check { messageIds }` (at most `savedCheckLimit` ids).
    func checkSaved(ids: [String]) async throws -> [String] {
        try await client.send(.json("POST", "channels/saved/check", body: ["messageIds": ids]), as: SavedCheck.self).savedIds
    }
}
