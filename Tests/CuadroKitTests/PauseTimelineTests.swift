import Foundation
import Testing
@testable import CuadroKit

struct PauseTimelineTests {
    /// Paused from 10 to 12 and from 20 to 25, then from 30 on.
    private static var timeline: PauseTimeline {
        var timeline = PauseTimeline()
        timeline.pause(at: 10)
        timeline.resume(at: 12)
        timeline.pause(at: 20)
        timeline.resume(at: 25)
        timeline.pause(at: 30)
        return timeline
    }

    struct TimeCase: Sendable, CustomTestStringConvertible {
        let name: String
        let time: Double
        let movie: Double?
        let clamped: Double
        let paused: Double
        var testDescription: String { name }
    }

    @Test(arguments: [
        TimeCase(name: "before any pause", time: 5, movie: 5, clamped: 5, paused: 0),
        TimeCase(name: "the moment a pause starts", time: 10, movie: nil, clamped: 10, paused: 0),
        TimeCase(name: "inside the first pause", time: 11, movie: nil, clamped: 10, paused: 1),
        TimeCase(name: "the moment it ends", time: 12, movie: 10, clamped: 10, paused: 2),
        TimeCase(name: "between pauses", time: 15, movie: 13, clamped: 13, paused: 2),
        TimeCase(name: "inside the second pause", time: 22, movie: nil, clamped: 18, paused: 4),
        TimeCase(name: "after two pauses", time: 26, movie: 19, clamped: 19, paused: 7),
        TimeCase(name: "inside the open pause", time: 40, movie: nil, clamped: 23, paused: 17),
    ])
    func times(_ testCase: TimeCase) {
        let timeline = Self.timeline
        #expect(timeline.movieTime(for: testCase.time) == testCase.movie)
        #expect(timeline.clampedMovieTime(for: testCase.time) == testCase.clamped)
        #expect(timeline.pausedDuration(until: testCase.time) == testCase.paused)
    }

    @Test func pauseState() {
        var timeline = PauseTimeline()
        #expect(!timeline.isPaused)
        timeline.pause(at: 1)
        #expect(timeline.isPaused)
        timeline.resume(at: 2)
        #expect(!timeline.isPaused)
    }

    @Test func repeatedCallsChangeNothing() {
        var once = PauseTimeline()
        once.pause(at: 10)
        once.resume(at: 12)
        var twice = PauseTimeline()
        twice.pause(at: 10)
        twice.pause(at: 11)
        twice.resume(at: 12)
        twice.resume(at: 13)
        #expect(once == twice)
    }

    @Test func outOfOrderTimesStayConsistent() {
        var timeline = PauseTimeline()
        timeline.pause(at: 10)
        // A resume stamped before its pause makes an empty pause.
        timeline.resume(at: 9)
        #expect(timeline.movieTime(for: 11) == 11)
        // A pause stamped before the last one ended is ignored.
        timeline.pause(at: 8)
        #expect(!timeline.isPaused)
    }

    @Test func emptyTimelinePassesTimesThrough() {
        let timeline = PauseTimeline()
        #expect(timeline.movieTime(for: 123.5) == 123.5)
        #expect(timeline.pausedDuration(until: 123.5) == 0)
    }
}
