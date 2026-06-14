import AppKit
import SwiftUI

/// Owns the user's timers and stopwatches and the operations on them.
///
/// An `ObservableObject` injected into the SwiftUI environment so the timer
/// views re-render on add/remove/pause. A light 0.5s tick latches countdown
/// firing (plays a sound, flips `hasFired`) — the *displayed* numbers advance
/// via `TimelineView` in the views, so the tick stays cheap.
@MainActor
final class TimerManager: ObservableObject {

    @Published private(set) var timers: [IslandTimer] = []

    private var tick: Timer?
    /// Repeating alarm while one or more countdowns are ringing (fired but not
    /// yet dismissed). Separate from `tick` so the chime cadence is its own.
    private var ringTimer: Timer?
    private var stopwatchCount = 0
    private var timerCount = 0
    /// User prefs (chime on/off, repeat). Optional so previews can omit it.
    private let settings: AppSettings?

    init(settings: AppSettings? = nil) {
        self.settings = settings
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t

        // DI_MOCK_TIMERS=1 seeds a few timers for previews/screenshots.
        if ProcessInfo.processInfo.environment["DI_MOCK_TIMERS"] == "1" {
            // DI_MOCK_FIRED=1 marks the "Tea" countdown as already fired so the
            // ringing visuals (red flash) can be screenshot. The alarm SOUND is
            // not started here — it only begins when a timer actually fires via
            // `advance()` — so seeding stays silent.
            let fired = ProcessInfo.processInfo.environment["DI_MOCK_FIRED"] == "1"
            timers = [
                IslandTimer(name: "Pasta", kind: .countdown, configuredDuration: 600,
                            isRunning: true, accumulated: 137, lastResume: Date()),
                IslandTimer(name: "Workout", kind: .stopwatch,
                            isRunning: true, accumulated: 752, lastResume: Date()),
                IslandTimer(name: "Tea", kind: .countdown, configuredDuration: 180,
                            isRunning: false,
                            accumulated: fired ? 180 : 60,
                            hasFired: fired),
            ]
            timerCount = 1
            stopwatchCount = 1
        }
    }

    deinit {
        tick?.invalidate()
        ringTimer?.invalidate()
    }

    // MARK: Derived

    /// Whether the timers app has anything live worth keeping the island open
    /// for: a running clock or a countdown that has fired and not been cleared.
    var hasActive: Bool {
        timers.contains { $0.isRunning || $0.hasFired }
    }

    /// Whether any countdown has fired and is still ringing (drives the alarm
    /// sound and the flashing red glow).
    var isRinging: Bool { timers.contains { $0.hasFired } }

    /// All timers ordered by how loudly they want attention — fired countdowns
    /// first, then running countdowns by nearness to firing, then running
    /// stopwatches, then anything paused. Stable for equal ranks (creation
    /// order) so islands don't reshuffle on every tick.
    func ordered(at date: Date = Date()) -> [IslandTimer] {
        func rank(_ t: IslandTimer) -> Int {
            if t.hasFired { return 0 }
            if t.isRunning { return t.kind == .countdown ? 1 : 2 }
            return 3
        }
        return timers.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            // Within running countdowns, soonest-to-fire first.
            if ra == 1 {
                let dr = a.element.remaining(at: date) - b.element.remaining(at: date)
                if dr != 0 { return dr < 0 }
            }
            return a.offset < b.offset
        }.map { $0.element }
    }

    /// The single most relevant timer for the compact / secondary-island readout.
    func headline(at date: Date = Date()) -> IslandTimer? {
        ordered(at: date).first
    }

    // MARK: Mutations

    @discardableResult
    func addCountdown(duration: TimeInterval, name: String? = nil) -> UUID {
        timerCount += 1
        let timer = IslandTimer(
            name: name?.isEmpty == false ? name! : "Timer \(timerCount)",
            kind: .countdown,
            configuredDuration: max(1, duration),
            isRunning: true,
            lastResume: Date())
        timers.append(timer)
        return timer.id
    }

    @discardableResult
    func addStopwatch(name: String? = nil) -> UUID {
        stopwatchCount += 1
        let timer = IslandTimer(
            name: name?.isEmpty == false ? name! : "Stopwatch \(stopwatchCount)",
            kind: .stopwatch,
            isRunning: true,
            lastResume: Date())
        timers.append(timer)
        return timer.id
    }

    /// Pause if running, resume if paused. A fired countdown can't resume.
    func toggleRun(_ id: UUID) {
        mutate(id) { t in
            let now = Date()
            if t.isRunning {
                t.accumulated = t.elapsed(at: now)
                t.isRunning = false
                t.lastResume = nil
            } else if !t.hasFired {
                t.isRunning = true
                t.lastResume = now
            }
        }
    }

    /// Stop and zero a timer (a fired countdown returns to its full duration,
    /// ready to run again).
    func reset(_ id: UUID) {
        mutate(id) { t in
            t.isRunning = false
            t.accumulated = 0
            t.lastResume = nil
            t.hasFired = false
        }
        syncRinging()
    }

    /// Silence and clear every ringing countdown: resets each to its full
    /// duration (stopped, ready to run again) and stops the alarm. Called when
    /// the user hovers the island — a glance is enough to acknowledge it.
    func dismissRinging() {
        guard isRinging else { return }
        for index in timers.indices where timers[index].hasFired {
            timers[index].hasFired = false
            timers[index].isRunning = false
            timers[index].accumulated = 0
            timers[index].lastResume = nil
        }
        syncRinging()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id) { $0.name = trimmed }
    }

    func remove(_ id: UUID) {
        timers.removeAll { $0.id == id }
        syncRinging()
    }

    // MARK: Ticking

    /// Latches countdown firing. Called twice a second.
    private func advance() {
        let now = Date()
        for index in timers.indices {
            var t = timers[index]
            guard t.kind == .countdown, t.isRunning, !t.hasFired else { continue }
            if t.isExpired(at: now) {
                t.isRunning = false
                t.accumulated = t.configuredDuration
                t.lastResume = nil
                t.hasFired = true
                timers[index] = t
            }
        }
        syncRinging()
    }

    private func mutate(_ id: UUID, _ body: (inout IslandTimer) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        var t = timers[index]
        body(&t)
        timers[index] = t
    }

    // MARK: Ringing

    /// Start or stop the repeating alarm to match whether anything is ringing.
    private func syncRinging() {
        if isRinging { startRinging() } else { stopRinging() }
    }

    private func startRinging() {
        guard ringTimer == nil else { return }
        playChime()
        // Only keep chiming if the user wants a repeating alarm (the red glow
        // still pulses regardless — that's driven by `isRinging`, not this timer).
        guard settings?.timerChimeRepeat ?? true else { return }
        let t = Timer(timeInterval: 1.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playChime() }
        }
        RunLoop.main.add(t, forMode: .common)
        ringTimer = t
    }

    private func stopRinging() {
        ringTimer?.invalidate()
        ringTimer = nil
    }

    private func playChime() {
        guard settings?.timerChimeEnabled ?? true else { return }
        NSSound(named: "Glass")?.play()
    }
}

/// Formats seconds as `H:MM:SS` (dropping the hour when zero) for timer readouts.
func formatClock(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
