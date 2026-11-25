import CoreGraphics
import SwiftUI
import Testing
@testable import Raft

/// Opening at a message (29c): the landing always ends at a definite position.
@MainActor
struct AnchoredLandingTests {
    private func geometry(visible: CGFloat, content: CGFloat) -> StreamGeometry {
        var geometry = StreamGeometry()
        geometry.visible = visible
        geometry.contentHeight = content
        return geometry
    }

    @Test func centresAMeasuredRowInsideTheRange() {
        let step = AnchoredLanding.finalStep(frame: CGRect(x: 0, y: 1000, width: 300, height: 40), geometry: geometry(visible: 600, content: 3000), resting: .bottom)
        #expect(step == .offset(720))
    }

    @Test func clampsNearTheEnds() {
        let g = geometry(visible: 600, content: 3000)
        #expect(AnchoredLanding.finalStep(frame: CGRect(x: 0, y: 20, width: 300, height: 40), geometry: g, resting: .bottom) == .offset(0))
        #expect(AnchoredLanding.finalStep(frame: CGRect(x: 0, y: 2950, width: 300, height: 40), geometry: g, resting: .top) == .offset(2400))
    }

    /// A task conversation with one status line: shorter than the screen, it stays at 0.
    @Test func shortContentLandsAtZero() {
        let g = geometry(visible: 700, content: 80)
        #expect(AnchoredLanding.finalStep(frame: CGRect(x: 0, y: 40, width: 300, height: 20), geometry: g, resting: .bottom) == .offset(0))
        #expect(AnchoredLanding.finalStep(frame: nil, geometry: g, resting: .bottom) == .offset(0))
    }

    /// The target never reported a frame (or is not a row of the stream): its resting edge.
    @Test func unmeasuredTargetFallsBackToTheRestingEdge() {
        let g = geometry(visible: 600, content: 3000)
        #expect(AnchoredLanding.finalStep(frame: nil, geometry: g, resting: .bottom) == .offset(2400))
        #expect(AnchoredLanding.finalStep(frame: nil, geometry: g, resting: .top) == .offset(0))
    }

    @Test func noGeometryYetUsesTheEdge() {
        #expect(AnchoredLanding.finalStep(frame: CGRect(x: 0, y: 500, width: 300, height: 40), geometry: StreamGeometry(), resting: .bottom) == .edge(.bottom))
    }

    /// The landing finishes by the deadline even when the row is never measured.
    @Test func landingEndsWithoutAFrame() async {
        var position = ScrollPosition(edge: .top)
        let binding = Binding(get: { position }, set: { position = $0 })
        let clock = ContinuousClock()
        let start = clock.now
        await AnchoredLanding.land(
            on: "m:missing",
            present: true,
            resting: .bottom,
            position: binding,
            geometry: { geometry(visible: 600, content: 3000) },
            target: { nil }
        )
        #expect(clock.now - start < .seconds(2))
        // Ends on an offset, not left on the id.
        #expect(position.viewID == nil)
    }

    @Test func absentTargetLandsAtOnce() async {
        var position = ScrollPosition(edge: .top)
        let binding = Binding(get: { position }, set: { position = $0 })
        let clock = ContinuousClock()
        let start = clock.now
        await AnchoredLanding.land(
            on: "m:elsewhere",
            present: false,
            resting: .top,
            position: binding,
            geometry: { geometry(visible: 600, content: 3000) },
            target: { nil }
        )
        #expect(clock.now - start < .milliseconds(250))
        #expect(position.viewID == nil)
    }
}
