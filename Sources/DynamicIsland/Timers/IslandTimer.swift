import Foundation

/// A countdown timer or an up-counting stopwatch.
enum TimerKind: String, Equatable {
    case countdown
    case stopwatch
}

/// A single timer/stopwatch the user has created.
///
/// Time is stored as `accumulated` (elapsed banked while paused) plus a live
/// span since `lastResume` while running, so the value advances smoothly without
/// per-tick mutation — views interpolate it with a `TimelineView`, mirroring how
/// the music progress bar works.
struct IslandTimer: Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: TimerKind

    /// Target duration for a countdown (seconds). Ignored for a stopwatch.
    var configuredDuration: TimeInterval

    /// Whether the clock is currently advancing.
    var isRunning: Bool

    /// Elapsed time banked from previous run spans (seconds).
    var accumulated: TimeInterval

    /// When the current run span started; `nil` while paused.
    var lastResume: Date?

    /// Set once a countdown reaches zero (latched until reset/removed).
    var hasFired: Bool

    init(id: UUID = UUID(),
         name: String,
         kind: TimerKind,
         configuredDuration: TimeInterval = 0,
         isRunning: Bool = false,
         accumulated: TimeInterval = 0,
         lastResume: Date? = nil,
         hasFired: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.configuredDuration = configuredDuration
        self.isRunning = isRunning
        self.accumulated = accumulated
        self.lastResume = lastResume
        self.hasFired = hasFired
    }

    /// Total elapsed time at `date`.
    func elapsed(at date: Date) -> TimeInterval {
        guard isRunning, let lastResume else { return accumulated }
        return accumulated + max(0, date.timeIntervalSince(lastResume))
    }

    /// Remaining time for a countdown (clamped at zero). Meaningless for a
    /// stopwatch, where it returns the elapsed time instead.
    func remaining(at date: Date) -> TimeInterval {
        guard kind == .countdown else { return elapsed(at: date) }
        return max(0, configuredDuration - elapsed(at: date))
    }

    /// The number the UI shows: counts down for a countdown, up for a stopwatch.
    func displayValue(at date: Date) -> TimeInterval {
        kind == .countdown ? remaining(at: date) : elapsed(at: date)
    }

    /// Fraction complete 0…1 (countdown only; stopwatch has no end).
    func fraction(at date: Date) -> Double {
        guard kind == .countdown, configuredDuration > 0 else { return 0 }
        return min(1, max(0, elapsed(at: date) / configuredDuration))
    }

    /// True once a running countdown has reached its target.
    func isExpired(at date: Date) -> Bool {
        kind == .countdown && elapsed(at: date) >= configuredDuration
    }
}
