import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Raft

// MARK: Fixtures

private func savedEntryJSON(_ id: String, channelId: String = "c1", type: String = "channel") -> String {
    #"{"messageId":"\#(id)","channelId":"\#(channelId)","channelName":"general","channelType":"\#(type)","content":"text \#(id)","senderType":"user","senderId":"u-2","senderName":"Amy","createdAt":"2026-11-20T10:00:00Z","savedAt":"2026-11-21T10:00:00Z"}"#
}

private func savedPageJSON(_ ids: [String], hasMore: Bool = false, globalTotal: Int, extraRaw: [String] = []) -> String {
    let items = ids.map { savedEntryJSON($0) } + extraRaw
    return #"{"saved":[\#(items.joined(separator: ","))],"hasMore":\#(hasMore),"total":\#(ids.count),"globalTotal":\#(globalTotal)}"#
}

private func decodePage(_ json: String) throws -> SavedPage {
    try RaftJSON.decode(SavedPage.self, from: Data(json.utf8))
}

private func decodeEntry(_ json: String) throws -> SavedEntry {
    try RaftJSON.decode(SavedEntry.self, from: Data(json.utf8))
}

/// The ids a `channels/saved/check` request asked about.
private func askedIds(_ request: FakeServer.Recorded) -> [String] {
    guard case .array(let values)? = request.json?["messageIds"] else { return [] }
    return values.compactMap(\.stringValue)
}

@MainActor
private func savedStore(_ core: TestCore, readOnly: Bool = false) -> SavedStore {
    SavedStore(api: core.api, preferences: .inMemory(readOnly: readOnly))
}

/// A store holding `ids` as its first (and only) page.
@MainActor
private func loadedStore(_ core: TestCore, _ ids: [String], readOnly: Bool = false) async -> SavedStore {
    core.server.on("GET channels/saved", .json(200, savedPageJSON(ids, globalTotal: ids.count)))
    let store = savedStore(core, readOnly: readOnly)
    await store.refresh()
    return store
}

// MARK: Parsing

struct SavedModelTests {
    @Test func pageTotalPrefersGlobalTotalThenTotalThenTotalCount() throws {
        #expect(try decodePage(#"{"saved":[],"hasMore":false,"total":3,"globalTotal":7}"#).total == 7)
        #expect(try decodePage(#"{"saved":[],"total":"3"}"#).total == 3)
        #expect(try decodePage(#"{"saved":[],"totalCount":4}"#).total == 4)
        #expect(try decodePage(savedPageJSON(["a", "b"], globalTotal: 9).replacingOccurrences(of: #","total":2,"globalTotal":9"#, with: "")).total == 2)
    }

    @Test func rawCountIncludesEntriesThatDoNotDecode() throws {
        let page = try decodePage(savedPageJSON(["a", "b"], hasMore: true, globalTotal: 40, extraRaw: [#"{"channelId":"c1"}"#, "17"]))
        #expect(page.saved.map(\.id) == ["a", "b"])
        #expect(page.rawCount == 4)
        #expect(page.hasMore)
    }

    @Test func entryLocationFollowsTheWebClient() throws {
        let channel = try decodeEntry(savedEntryJSON("m1"))
        #expect(!channel.isThreadReply && !channel.isTask && !channel.isDirectMessage)
        #expect(channel.attachments.isEmpty)

        let dm = try decodeEntry(savedEntryJSON("m2", channelId: "d1", type: "dm"))
        #expect(dm.isDirectMessage && !dm.isThreadReply)

        let dmThread = try decodeEntry(#"{"messageId":"m3","channelId":"t1","channelType":"thread","parentChannelId":"d1","parentChannelName":"dm-amy","parentChannelType":"dm","parentMessageId":"p1","content":"x"}"#)
        #expect(dmThread.isThreadReply && dmThread.isDirectMessage)
        #expect(dmThread.parentChannelType == "dm")

        // A reply known only by its parent message still counts as a thread reply.
        let reply = try decodeEntry(#"{"messageId":"m4","channelId":"t2","parentChannelId":"c1","parentMessageId":"p2","content":"x"}"#)
        #expect(reply.isThreadReply && !reply.isDirectMessage)

        let task = try decodeEntry(#"{"messageId":"m5","channelId":"k1","channelType":"task","parentChannelId":"c1","parentChannelName":"general","parentChannelType":"channel","content":"x"}"#)
        #expect(task.isTask && !task.isThreadReply && !task.isDirectMessage)
    }

    @Test func entryAttachmentsAreReadLeniently() throws {
        let json = #"{"messageId":"m1","channelId":"c1","content":"","attachments":[{"id":"a1","filename":"hero.png","mimeType":"image/png","thumbnailUrl":"https://cdn.raft.build/thumbs/a/b.webp"},{"filename":"no-id.png"},"x"]}"#
        let entry = try decodeEntry(json)
        #expect(entry.attachments.map(\.id) == ["a1"])
        #expect(entry.attachments.first?.isImage == true)
    }

    @Test func checkDropsBlankIds() throws {
        let check = try RaftJSON.decode(SavedCheck.self, from: Data(#"{"savedIds":["m1","","m2"]}"#.utf8))
        #expect(check.savedIds == ["m1", "m2"])
        let empty = try RaftJSON.decode(SavedCheck.self, from: Data(#"{}"#.utf8))
        #expect(empty.savedIds.isEmpty)
    }

    @Test func attachmentReadsTheRasterPreview() throws {
        let json = #"{"id":"a1","filename":"raw.dng","mimeType":"image/x-adobe-dng","rasterPreviewUrl":"https://cdn.raft.build/raster/a1.png"}"#
        let attachment = try RaftJSON.decode(MessageAttachment.self, from: Data(json.utf8))
        #expect(attachment.rasterPreviewUrl == "https://cdn.raft.build/raster/a1.png")
        #expect(attachment.thumbnailUrl == nil)
    }
}

// MARK: Store

@MainActor
struct SavedStoreTests {
    @Test func saveIsShownAtOnceThenConfirmed() async throws {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/saved", .json(201, #"{"ok":true}"#))
        let store = await loadedStore(core, ["a"])
        core.server.latency = 0.2
        let save = Task { await store.setSaved("m1", true) }
        #expect(await eventually { await MainActor.run { store.isSaved("m1") } })
        #expect(store.total == 2)
        #expect(store.feedback == nil)
        await save.value
        #expect(store.isSaved("m1"))
        #expect(store.total == 2)
        #expect(store.feedback?.kind == .saved)
        let request = try #require(core.server.requests("POST channels/saved").first)
        #expect(request.json == ["messageId": "m1"])
    }

    @Test func failedSaveGoesBackAndReports() async {
        let core = TestCore(session: sampleSession())
        let store = await loadedStore(core, ["a", "b"])
        core.server.on("POST channels/saved", .json(500, #"{"error":"boom"}"#))
        await store.setSaved("m1", true)
        #expect(!store.isSaved("m1"))
        #expect(store.total == 2)
        #expect(store.feedback?.kind == .saveFailed)
    }

    @Test func alreadySavedAndNotSavedAnswersCountAsDone() async {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/saved", .json(409, #"{"error":"Already saved","code":"already_saved"}"#))
        core.server.on("DELETE channels/saved/m1", .json(404, #"{"error":"Not found"}"#))
        let store = savedStore(core)
        await store.setSaved("m1", true)
        #expect(store.isSaved("m1"))
        #expect(store.feedback?.kind == .saved)
        await store.setSaved("m1", false)
        #expect(!store.isSaved("m1"))
        #expect(store.feedback?.kind == .removed)
        #expect(core.server.count("DELETE channels/saved/m1") == 1)
    }

    @Test func aChangeDuringARequestIsSentAfterIt() async {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/saved", .json(200, "{}"))
        core.server.on("DELETE channels/saved/m1", .json(200, "{}"))
        core.server.latency = 0.15
        let store = savedStore(core)
        let server = core.server
        let save = Task { await store.setSaved("m1", true) }
        #expect(await eventually { server.count("POST channels/saved") == 1 })
        // Removed again while the save is on its way: shown at once, sent once the save is back.
        await store.setSaved("m1", false)
        #expect(!store.isSaved("m1"))
        #expect(core.server.count("DELETE channels/saved/m1") == 0)
        await save.value
        #expect(core.server.count("POST channels/saved") == 1)
        #expect(core.server.count("DELETE channels/saved/m1") == 1)
        #expect(!store.isSaved("m1"))
        #expect(store.feedback?.kind == .removed)
    }

    @Test func togglingBackDuringARequestSendsNothingMore() async {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/saved", .json(200, "{}"))
        core.server.latency = 0.15
        let store = savedStore(core)
        let server = core.server
        let first = Task { await store.setSaved("m1", true) }
        #expect(await eventually { server.count("POST channels/saved") == 1 })
        await store.setSaved("m1", false)
        await store.setSaved("m1", true)
        await first.value
        #expect(core.server.count("POST channels/saved") == 1)
        #expect(core.server.count("DELETE channels/saved/m1") == 0)
        #expect(store.isSaved("m1"))
    }

    @Test func failedRemovalPutsTheRowBackInItsPlace() async throws {
        let core = TestCore(session: sampleSession())
        let store = await loadedStore(core, ["a", "b", "c"])
        core.server.on("DELETE channels/saved/b", .json(500, "{}"))
        core.server.latency = 0.15
        let entry = try #require(store.entries.first { $0.id == "b" })
        let remove = Task { await store.setSaved("b", false, entry: entry) }
        #expect(await eventually { await MainActor.run { store.entries.map(\.id) == ["a", "c"] } })
        #expect(store.total == 2)
        await remove.value
        #expect(store.entries.map(\.id) == ["a", "b", "c"])
        #expect(store.isSaved("b"))
        #expect(store.total == 3)
        #expect(store.feedback?.kind == .removeFailed)
    }

    @Test func removalFromTheListTakesTheRowOut() async throws {
        let core = TestCore(session: sampleSession())
        let store = await loadedStore(core, ["a", "b"])
        core.server.on("DELETE channels/saved/a", .json(200, "{}"))
        let entry = try #require(store.entries.first)
        await store.setSaved("a", false, entry: entry)
        #expect(store.entries.map(\.id) == ["b"])
        #expect(store.total == 1)
        #expect(!store.isSaved("a"))
        #expect(store.feedback?.kind == .removed)
    }

    @Test func readOnlyRefusesWithoutARequest() async {
        let core = TestCore(session: sampleSession())
        let store = await loadedStore(core, ["a"], readOnly: true)
        await store.setSaved("m1", true)
        await store.setSaved("a", false)
        #expect(!store.isSaved("m1"))
        #expect(store.isSaved("a"))
        #expect(store.feedback?.kind == .readOnly)
        #expect(core.server.count("POST channels/saved") == 0)
        #expect(core.server.count("DELETE channels/saved/a") == 0)
    }

    @Test func checkAsksInChunksOf200AndSkipsLocalIds() async {
        let core = TestCore(session: sampleSession())
        core.server.on("POST channels/saved/check") { request, _ in
            let saved = askedIds(request).filter { ["id-5", "id-300"].contains($0) }
            return .json(200, #"{"savedIds":[\#(saved.map { "\"\($0)\"" }.joined(separator: ","))]}"#)
        }
        let store = await loadedStore(core, ["id-7"])
        #expect(store.isSaved("id-7"))
        let ids = (0..<450).map { "id-\($0)" } + ["ios-local-1", "id-5", ""]
        await store.check(ids)
        let requests = core.server.requests("POST channels/saved/check")
        #expect(requests.map { askedIds($0).count } == [200, 200, 50])
        #expect(!requests.flatMap(askedIds).contains { $0.hasPrefix("ios-") || $0.isEmpty })
        #expect(store.isSaved("id-5"))
        #expect(store.isSaved("id-300"))
        // Removed elsewhere: the check takes the mark away.
        #expect(!store.isSaved("id-7"))
    }

    @Test func aFailedCheckKeepsWhatIsShown() async {
        let core = TestCore(session: sampleSession())
        let store = await loadedStore(core, ["a"])
        core.server.on("POST channels/saved/check", .json(500, "{}"))
        await store.check(["a", "b"])
        #expect(store.isSaved("a"))
        #expect(store.feedback == nil)
    }

    @Test func pagesAdvanceByWhatTheServerSentAndDropRepeats() async throws {
        let core = TestCore(session: sampleSession())
        let first = savedPageJSON(["a", "b"], hasMore: true, globalTotal: 4, extraRaw: [#"{"channelId":"c1"}"#])
        let second = savedPageJSON(["b", "c"], hasMore: false, globalTotal: 4)
        core.server.on("GET channels/saved") { request, _ in
            .json(200, request.query["offset"] == "0" ? first : second)
        }
        let store = savedStore(core)
        await store.refresh()
        #expect(store.phase == .loaded)
        #expect(store.entries.map(\.id) == ["a", "b"])
        #expect(store.total == 4)
        #expect(store.hasMore)
        await store.loadMore()
        let more = try #require(core.server.requests("GET channels/saved").last)
        #expect(more.query["offset"] == "3")
        #expect(more.query["limit"] == "30")
        #expect(store.entries.map(\.id) == ["a", "b", "c"])
        #expect(!store.hasMore)
        // Pulling to refresh merges the first page and keeps the second.
        await store.refresh()
        #expect(store.entries.map(\.id) == ["a", "b", "c"])
    }

    @Test func firstPageFailureSaysWhetherItIsTheConnection() async {
        let core = TestCore(session: sampleSession())
        core.server.on("GET channels/saved", .transportFailure(.notConnectedToInternet))
        let offline = savedStore(core)
        await offline.refresh()
        #expect(offline.phase == .failed(offline: true))

        let failing = TestCore(session: sampleSession())
        failing.server.on("GET channels/saved", .json(500, "{}"))
        let broken = savedStore(failing)
        await broken.refresh()
        #expect(broken.phase == .failed(offline: false))
    }

    @Test func unavailableMessageLeavesTheListForGood() async {
        let core = TestCore(session: sampleSession())
        let store = await loadedStore(core, ["a", "b"])
        core.server.on("DELETE channels/saved/b", .json(500, "{}"))
        await store.removeUnavailable("b")
        #expect(store.entries.map(\.id) == ["a"])
        #expect(!store.isSaved("b"))
        #expect(store.total == 1)
        #expect(store.feedback?.kind == .unavailable)
        #expect(core.server.count("DELETE channels/saved/b") == 1)
    }

    @Test func homeCountWaitsForChangesOnTheirWay() async throws {
        let core = TestCore(session: sampleSession())
        let store = savedStore(core)
        let page = try decodePage(#"{"saved":[],"globalTotal":12}"#)
        store.absorbTotal(page)
        #expect(store.total == 12)
        core.server.on("POST channels/saved", .json(200, "{}"))
        core.server.latency = 0.15
        let server = core.server
        let save = Task { await store.setSaved("m1", true) }
        #expect(await eventually { server.count("POST channels/saved") == 1 })
        // Home's count read meanwhile does not undo the save on screen.
        store.absorbTotal(page)
        #expect(store.total == 13)
        await save.value
    }
}

// MARK: Attachment URLs

@MainActor
struct AttachmentPrefetchTests {
    @Test func signsInBatchesOf50AndAsksMissingOnesAlone() async {
        let core = TestCore(session: sampleSession())
        core.server.on("POST attachments/urls") { request, _ in
            guard case .array(let values)? = request.json?["attachmentIds"] else { return .json(400, "{}") }
            let urls = values.compactMap(\.stringValue).filter { $0 != "att-7" }.map { #"{"id":"\#($0)","url":"https://r2.example/\#($0)","expiresAt":null}"# }
            return .json(200, #"{"urls":[\#(urls.joined(separator: ","))]}"#)
        }
        core.server.on("GET attachments/att-7/url", .json(200, #"{"url":"https://r2.example/att-7?single","expiresAt":"2026-11-25T10:05:00Z"}"#))
        let store = AttachmentStore(api: core.api)
        let ids = (0..<120).map { "att-\($0)" }
        let urls = await store.prefetchURLs(for: ids + ["att-3"])
        let batches = core.server.requests("POST attachments/urls").map { request -> Int in
            guard case .array(let values)? = request.json?["attachmentIds"] else { return 0 }
            return values.count
        }
        #expect(batches == [50, 50, 20])
        #expect(urls.count == 120)
        #expect(urls["att-7"]?.absoluteString == "https://r2.example/att-7?single")
        #expect(core.server.count("GET attachments/att-7/url") == 1)
        // Signed URLs are reused.
        _ = await store.prefetchURLs(for: ["att-1", "att-7"])
        #expect(core.server.count("POST attachments/urls") == 3)
    }
}

// MARK: Images

struct MessageImageLayoutTests {
    @Test func firstImageIsFourByThreeWhenItsSizeIsUnknown() {
        #expect(MessageImageLayout.first(width: nil, height: nil, column: 300) == CGSize(width: 240, height: 180))
        #expect(MessageImageLayout.first(width: 0, height: 10, column: 200) == CGSize(width: 200, height: 150))
    }

    @Test func firstImageHeightFollowsItsRatioWithinLimits() {
        #expect(MessageImageLayout.first(width: 400, height: 300, column: 240) == CGSize(width: 240, height: 180))
        #expect(MessageImageLayout.first(width: 1000, height: 3000, column: 240).height == 320)
        #expect(MessageImageLayout.first(width: 3000, height: 1000, column: 240).height == 120)
    }

    @Test func gridShowsFiveWithACountOfTheRest() {
        #expect(MessageImageLayout.tile == CGSize(width: 116, height: 87))
        #expect(MessageImageLayout.shown(Array(1...7)) == [1, 2, 3, 4, 5])
        #expect(MessageImageLayout.overflow(count: 7) == 2)
        #expect(MessageImageLayout.overflow(count: 5) == 0)
        #expect(MessageImageLayout.overflow(count: 1) == 0)
    }

    @Test func undecodableTypesUseTheRasterPreview() throws {
        #expect(MessageImageLayout.isDecodable("image/png"))
        #expect(MessageImageLayout.isDecodable("IMAGE/JPEG"))
        #expect(!MessageImageLayout.isDecodable("image/svg+xml"))
        #expect(!MessageImageLayout.isDecodable("application/pdf"))

        func attachment(_ json: String) throws -> MessageAttachment {
            try RaftJSON.decode(MessageAttachment.self, from: Data(json.utf8))
        }
        let thumb = try attachment(#"{"id":"a","mimeType":"image/png","thumbnailUrl":"https://cdn.raft.build/thumbs/a.webp","rasterPreviewUrl":"https://cdn.raft.build/raster/a.png"}"#)
        #expect(MessageImageLayout.thumbnailURL(thumb)?.absoluteString == "https://cdn.raft.build/thumbs/a.webp")
        let raw = try attachment(#"{"id":"b","mimeType":"image/x-adobe-dng","rasterPreviewUrl":"https://cdn.raft.build/raster/b.png"}"#)
        #expect(MessageImageLayout.thumbnailURL(raw)?.absoluteString == "https://cdn.raft.build/raster/b.png")
        let plain = try attachment(#"{"id":"c","mimeType":"image/png","rasterPreviewUrl":"https://cdn.raft.build/raster/c.png"}"#)
        #expect(MessageImageLayout.thumbnailURL(plain) == nil)
    }
}

struct ImageViewerDismissTests {
    @Test func takesMostlyDownwardDrags() {
        #expect(ImageViewerDismiss.claims(dx: 0, dy: 10))
        #expect(ImageViewerDismiss.claims(dx: -7, dy: 10))
        #expect(!ImageViewerDismiss.claims(dx: 8, dy: 10))
        #expect(!ImageViewerDismiss.claims(dx: 0, dy: -10))
        #expect(!ImageViewerDismiss.claims(dx: 0, dy: 0))
    }

    @Test func closesPastTheDistanceOrWhenFlung() {
        #expect(ImageViewerDismiss.closes(dy: 121, velocityY: 0))
        #expect(ImageViewerDismiss.closes(dy: 20, velocityY: 1001))
        #expect(!ImageViewerDismiss.closes(dy: 120, velocityY: 1000))
    }

    @Test func shrinksAndFadesWithTheDrag() {
        #expect(ImageViewerDismiss.scale(dy: 0, height: 800) == 1)
        #expect(abs(ImageViewerDismiss.scale(dy: 800, height: 800) - 0.8) < 0.0001)
        #expect(abs(ImageViewerDismiss.scale(dy: 1600, height: 800) - 0.8) < 0.0001)
        #expect(ImageViewerDismiss.fade(dy: 100, height: 800) == 0.75)
        #expect(ImageViewerDismiss.fade(dy: 400, height: 800) == 0)
        #expect(ImageViewerDismiss.fade(dy: -40, height: 800) == 1)
    }

    @Test func fitsTheImageCentered() {
        let rect = ImageViewerDismiss.fitted(CGSize(width: 400, height: 300), in: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(rect == CGRect(x: 0, y: 250, width: 400, height: 300))
        let tall = ImageViewerDismiss.fitted(CGSize(width: 100, height: 400), in: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(tall == CGRect(x: 100, y: 0, width: 200, height: 800))
    }
}

struct ImageViewerFitTests {
    /// iPhone Duo folded (measured): the system's column (status, Close at x 399–437, Share) is the
    /// window's 84pt right safe area; the info capsule's top is at 584.
    @Test func keepsOutOfTheSystemColumnAndAboveTheCapsule() {
        let layout = ImageViewerFit.Layout(
            size: CGSize(width: 466, height: 678),
            windowSafe: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84),
            pageSafe: UIEdgeInsets(top: 24, left: 0, bottom: 34, right: 84),
            verticalBar: true,
            capsule: CGRect(x: 16, y: 584, width: 350, height: 60)
        )
        let insets = ImageViewerFit.insets(layout)
        #expect(insets == UIEdgeInsets(top: 0, left: 0, bottom: CGFloat(106), right: CGFloat(84)))
        let region = CGRect(origin: .zero, size: layout.size).inset(by: insets)
        let image = ImageViewerDismiss.fitted(CGSize(width: 1600, height: 1000), in: region)
        let buttons = CGRect(x: 399, y: 179, width: 38, height: 98)
        #expect(!image.intersects(buttons))
        #expect(!image.intersects(layout.capsule!))
        #expect(image.maxY <= CGFloat(572))
    }

    /// A horizontal bar: the page's safe area holds it; the page counter pushes the top down.
    @Test func keepsBelowAHorizontalBarAndTheCounter() {
        let layout = ImageViewerFit.Layout(
            size: CGSize(width: 402, height: 874),
            windowSafe: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
            pageSafe: UIEdgeInsets(top: 116, left: 0, bottom: 34, right: 0),
            capsule: CGRect(x: 16, y: 780, width: 370, height: 60),
            counter: CGRect(x: 170, y: 122, width: 60, height: 32)
        )
        let insets = ImageViewerFit.insets(layout)
        #expect(insets == UIEdgeInsets(top: CGFloat(166), left: 0, bottom: CGFloat(106), right: 0))
    }

    @Test func centresInTheRegionAndScrollsToItsEdgesWhenLarger() {
        let fit = UIEdgeInsets(top: 0, left: 0, bottom: 110, right: 98)
        let bounds = CGSize(width: 466, height: 678)
        let small = ImageViewerFit.centering(content: CGSize(width: 368, height: 230), bounds: bounds, fit: fit)
        #expect(small == UIEdgeInsets(top: CGFloat(169), left: 0, bottom: CGFloat(279), right: CGFloat(98)))
        let zoomed = ImageViewerFit.centering(content: CGSize(width: 920, height: 575), bounds: bounds, fit: fit)
        #expect(zoomed == fit)
    }
}

@MainActor
struct ImageViewerFormatTests {
    @Test func saysTodayAndYesterdayBeforeTheTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15)))
        let today = now.addingTimeInterval(-3600)
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let older = now.addingTimeInterval(-10 * 24 * 3600)
        let clock = RaftFormat.clock(today)
        #expect(ImageViewerFormat.time(today, now: now, calendar: calendar).hasSuffix(clock))
        #expect(ImageViewerFormat.time(today, now: now, calendar: calendar).hasPrefix(L10n.t("activity_list_day_today", "Today")))
        #expect(ImageViewerFormat.time(yesterday, now: now, calendar: calendar).hasPrefix(L10n.t("activity_list_day_yesterday", "Yesterday")))
        let old = ImageViewerFormat.time(older, now: now, calendar: calendar)
        #expect(!old.hasPrefix(L10n.t("activity_list_day_today", "Today")) && !old.hasPrefix(L10n.t("activity_list_day_yesterday", "Yesterday")))
    }
}
