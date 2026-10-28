import Foundation

/// The pauses of a screen recording on the capture clock, in seconds. A movie leaves them out:
/// what was captured during a pause is dropped, and everything after it moves back by the pauses
/// before it, so the movie runs on without a gap.
public struct PauseTimeline: Equatable, Sendable {
    private struct Pause: Equatable, Sendable {
        var start: Double
        /// Nil while the pause lasts.
        var end: Double?
    }

    private var pauses: [Pause] = []

    public init() {}

    public var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    /// Pauses at `time`; ignored while paused or before the end of the last pause.
    public mutating func pause(at time: Double) {
        guard !isPaused, time >= (pauses.last?.end ?? -.infinity) else { return }
        pauses.append(Pause(start: time, end: nil))
    }

    /// Resumes at `time`, or at the pause's start if `time` comes before it.
    public mutating func resume(at time: Double) {
        guard isPaused, let last = pauses.indices.last else { return }
        pauses[last].end = max(time, pauses[last].start)
    }

    /// Where something captured at `time` goes in the movie, or nil when a pause drops it.
    public func movieTime(for time: Double) -> Double? {
        var shift = 0.0
        for pause in pauses {
            if time < pause.start { break }
            guard let end = pause.end, time >= end else { return nil }
            shift += end - pause.start
        }
        return time - shift
    }

    /// Where the movie is at `time`: inside a pause, where that pause started.
    public func clampedMovieTime(for time: Double) -> Double {
        var shift = 0.0
        for pause in pauses {
            if time < pause.start { break }
            guard let end = pause.end, time >= end else { return pause.start - shift }
            shift += end - pause.start
        }
        return time - shift
    }

    /// The paused time up to `time`.
    public func pausedDuration(until time: Double) -> Double {
        time - clampedMovieTime(for: time)
    }
}
