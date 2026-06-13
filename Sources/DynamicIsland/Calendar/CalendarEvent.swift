import SwiftUI

/// A single calendar event, flattened from EventKit into a value type the island
/// can hold and diff cheaply (so it doesn't retain `EKEvent`s or touch the store
/// off the main actor).
struct CalendarEvent: Identifiable, Equatable {
    let id: String
    var title: String
    var location: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    /// The owning calendar's colour, used for the leading bar / dot.
    var color: Color

    /// Seconds until the event starts (negative once it has started).
    func timeUntilStart(at date: Date = Date()) -> TimeInterval {
        start.timeIntervalSince(date)
    }

    /// Whether the event is happening right now.
    func isOngoing(at date: Date = Date()) -> Bool {
        date >= start && date < end
    }

    /// Whether the event has fully passed.
    func isPast(at date: Date = Date()) -> Bool {
        date >= end
    }

    /// `start`'s clock time, e.g. "9:30 AM" (or "all-day").
    var startTimeText: String {
        if isAllDay { return "all-day" }
        return CalendarEvent.timeFormatter.string(from: start)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()
}
