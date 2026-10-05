import Testing

@testable import Mosaic

// Transport geometry is pure, so gesture and scrubber behavior is checked without AVFoundation.
struct PlayerTests {
    @Test func doubleTapZonesSplitIntoThirds() {
        #expect(PlaybackMath.zone(x: 10, width: 300) == .leading)
        #expect(PlaybackMath.zone(x: 99, width: 300) == .leading)
        #expect(PlaybackMath.zone(x: 150, width: 300) == .center)
        #expect(PlaybackMath.zone(x: 201, width: 300) == .trailing)
        #expect(PlaybackMath.zone(x: 10, width: 0) == .center)
        #expect(PlaybackMath.zone(x: .nan, width: 300) == .center)
    }
    @Test func scrubLocationMapsToClampedTime() {
        #expect(PlaybackMath.time(at: 50, width: 200, duration: 120) == 30)
        #expect(PlaybackMath.time(at: -40, width: 200, duration: 120) == 0)
        #expect(PlaybackMath.time(at: 900, width: 200, duration: 120) == 120)
        #expect(PlaybackMath.time(at: 50, width: 0, duration: 120) == 0)
        #expect(PlaybackMath.time(at: 50, width: 200, duration: 0) == 0)
    }
    @Test func progressFractionIsBoundedAndSafe() {
        #expect(PlaybackMath.fraction(of: 30, duration: 120) == 0.25)
        #expect(PlaybackMath.fraction(of: 300, duration: 120) == 1)
        #expect(PlaybackMath.fraction(of: 10, duration: 0) == 0)
        #expect(PlaybackMath.fraction(of: .infinity, duration: 120) == 0)
        #expect(PlaybackMath.fraction(of: 10, duration: .nan) == 0)
    }
    @Test func seekTargetsStayInsideTheItem() {
        #expect(PlaybackMath.clamp(-5, duration: 60) == 0)
        #expect(PlaybackMath.clamp(75, duration: 60) == 60)
        #expect(PlaybackMath.clamp(75, duration: 0) == 75)
        #expect(PlaybackMath.clamp(.nan, duration: 60) == 0)
    }
    @Test func remainingTimeCountsDown() {
        #expect(PlaybackMath.remainingLabel(30, duration: 125) == "-1:35")
        #expect(PlaybackMath.remainingLabel(200, duration: 125) == "-0:00")
        #expect(PlaybackMath.remainingLabel(0, duration: 3_725) == "-1:02:05")
    }
    @Test func bufferedEndUsesOnlyTheRangeAroundThePlayhead() {
        let ranges: [(start: Double, end: Double)] = [(0, 20), (40, 90)]
        #expect(PlaybackMath.bufferedEnd(at: 10, ranges: ranges) == 20)
        #expect(PlaybackMath.bufferedEnd(at: 50, ranges: ranges) == 90)
        #expect(PlaybackMath.bufferedEnd(at: 30, ranges: ranges) == 0)
        #expect(PlaybackMath.bufferedEnd(at: 5, ranges: [(.nan, 9)]) == 0)
    }
    @Test @MainActor func detachedToolsIgnoreTransportCommands() {
        let tools = PlaybackTools()
        tools.togglePlay()
        tools.beginScrub()
        tools.scrub(to: 12)
        tools.beginBoost()
        #expect(!tools.scrubbing)
        #expect(!tools.boosting)
        #expect(tools.displayTime == 0)
        tools.setMuted(true)
        tools.setSpeed(1.5)
        #expect(tools.muted)
        #expect(tools.speed == 1.5)
    }
}
