import Combine
import SwiftUI

/// Owns the user's upcoming calendar events and the derived "imminent event"
/// live-activity state.
///
/// An `ObservableObject` (mirroring `TimerManager`) injected into the controller
/// so the calendar views re-render when events change. The actual EventKit fetch
/// lives in `EventKitProvider`, which pushes flattened `CalendarEvent`s here; the
/// manager only stores them, exposes query helpers for the views, and runs a
/// light ticker so the island re-evaluates imminence as time passes.
@MainActor
final class CalendarManager: ObservableObject {

    /// Upcoming events, sorted by start. Spans roughly a month back to a few
    /// months forward so the month/week grids have data to draw.
    @Published private(set) var events: [CalendarEvent] = []

    /// Whether calendar access has been granted. Drives the expanded view's
    /// permission placeholder.
    @Published private(set) var authorized: Bool = false

    /// User prefs (the live-activity lead time).
    private let settings: AppSettings?

    /// Events beginning within this window trigger the notch live activity. Driven
    /// by the user's "alert lead time" setting (minutes).
    var imminentWindow: TimeInterval { TimeInterval((settings?.calendarLeadMinutes ?? 15) * 60) }

    private var ticker: Timer?
    /// Identity of the current imminent event, so the ticker only republishes on
    /// a transition (event becomes / stops being imminent) rather than every second.
    private var lastImminentID: String?

    init(settings: AppSettings? = nil) {
        self.settings = settings
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.evaluateImminence()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        if ProcessInfo.processInfo.environment["DI_MOCK_CALENDAR"] == "1" {
            authorized = true
            events = Self.mockEvents()
        }
    }

    deinit { ticker?.invalidate() }

    // MARK: Updates (from the provider)

    func setEvents(_ events: [CalendarEvent]) {
        self.events = events.sorted { $0.start < $1.start }
        evaluateImminence()
    }

    func setAuthorized(_ authorized: Bool) {
        guard self.authorized != authorized else { return }
        self.authorized = authorized
    }

    // MARK: Imminent live activity

    /// The next event that begins within `imminentWindow` and hasn't started yet
    /// — the one the notch live activity counts down to. Timed (non-all-day)
    /// events only.
    func imminentEvent(at date: Date = Date()) -> CalendarEvent? {
        events
            .filter { !$0.isAllDay }
            .filter { $0.start > date && $0.start.timeIntervalSince(date) <= imminentWindow }
            .min { $0.start < $1.start }
    }

    /// Whether a live activity should be showing right now.
    var hasImminentEvent: Bool { imminentEvent() != nil }

    /// Re-check imminence and nudge observers only when it changes, so the island
    /// flips into / out of the live activity without thrashing layout each tick.
    private func evaluateImminence() {
        let id = imminentEvent()?.id
        guard id != lastImminentID else { return }
        lastImminentID = id
        objectWillChange.send()
    }

    // MARK: Query helpers for the views

    private var calendar: Calendar { Calendar.current }

    /// Upcoming (not-yet-ended) events from `date` onward, in order.
    func upcoming(from date: Date = Date()) -> [CalendarEvent] {
        events.filter { !$0.isPast(at: date) }
    }

    /// Events overlapping the given calendar day, in start order.
    func events(on day: Date) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events
            .filter { $0.start < end && $0.end > start }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay && !rhs.isAllDay }
                return lhs.start < rhs.start
            }
    }

    /// True if any event touches the given day (drives the month-grid dots).
    func hasEvents(on day: Date) -> Bool { !events(on: day).isEmpty }

    /// Upcoming events grouped by day (start-of-day key), each group sorted, the
    /// groups themselves chronological. Powers the right-hand "Up Next" list.
    func upcomingGroupedByDay(from date: Date = Date(), limitDays: Int = 60) -> [(day: Date, events: [CalendarEvent])] {
        let horizon = calendar.date(byAdding: .day, value: limitDays, to: calendar.startOfDay(for: date)) ?? date
        let relevant = events.filter { !$0.isPast(at: date) && $0.start < horizon }
        let groups = Dictionary(grouping: relevant) { calendar.startOfDay(for: $0.start) }
        return groups
            .map { (day: $0.key, events: $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.day < $1.day }
    }

    // MARK: Mock

    private static func mockEvents() -> [CalendarEvent] {
        let now = Date()
        let cal = Calendar.current
        func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }
        let red = Palette.red
        let blue = Palette.blue
        let green = Palette.green
        let purple = Palette.purple
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        return [
            CalendarEvent(id: "m1", title: "Design Review", location: "Zoom",
                          start: at(8 * 60), end: at(8 * 60 + 30 * 60),
                          isAllDay: false, color: blue),
            CalendarEvent(id: "m2", title: "Lunch with Sam", location: "Café Loup",
                          start: at(3 * 3600), end: at(4 * 3600),
                          isAllDay: false, color: green),
            CalendarEvent(id: "m3", title: "1:1 with Manager", location: nil,
                          start: at(5 * 3600), end: at(5 * 3600 + 1800),
                          isAllDay: false, color: red),
            CalendarEvent(id: "m4", title: "Standup",
                          location: "Conf Room B",
                          start: startOfTomorrow.addingTimeInterval(9.5 * 3600),
                          end: startOfTomorrow.addingTimeInterval(10 * 3600),
                          isAllDay: false, color: purple),
            CalendarEvent(id: "m5", title: "Flight to SFO", location: "SEA",
                          start: startOfTomorrow.addingTimeInterval(14 * 3600),
                          end: startOfTomorrow.addingTimeInterval(17 * 3600),
                          isAllDay: false, color: blue),
            CalendarEvent(id: "m6", title: "Conference", location: "Moscone",
                          start: cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: now))!,
                          end: cal.date(byAdding: .day, value: 4, to: cal.startOfDay(for: now))!,
                          isAllDay: true, color: red),
        ]
    }
}
