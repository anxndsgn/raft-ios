import CoreGraphics
import Testing
@testable import Raft

@Suite struct MessageTextSizeTests {
    @Test func bodySizes() {
        #expect(MessageTextSize.small.bodySize == 15)
        #expect(MessageTextSize.medium.bodySize == 16)
        #expect(MessageTextSize.large.bodySize == 17)
    }

    @Test func snippetsMoveInStep() {
        #expect(MessageTextSize.allCases.map(\.step) == [-2, -1, 0])
        #expect(MessageTextSize.allCases.map(\.snippetSize) == [13, 14, 15])
    }

    @Test func defaultAndStorage() {
        #expect(defaultMessageTextSize == .small)
        #expect(MessageTextSize.storageKey == "messageTextSize")
        #expect(MessageTextSize(rawValue: "large") == .large)
        #expect(MessageTextSize.allCases == [.small, .medium, .large])
    }

    @Test func bodyFontScalesWithDynamicType() {
        let font = MessageTextSize.small.bodyFont(scale: 1.2)
        #expect(font.family == .system)
        #expect(font.relativeTo == .body)
        #expect(font.size == 15)
        #expect(font.systemScale == 1.2)
        // No extra line spacing: the system face's own leading scales with the size.
        #expect(font.lineSpacing == 0)
        #expect(MessageTextSize.large.snippetFont().relativeTo == .subheadline)
    }
}
