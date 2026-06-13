import AppKit
import Combine
import EventKit
import SwiftUI

/// Feeds the island's `CalendarManager` from EventKit.
///
/// Requests calendar access, fetches a rolling window of events (about a month
/// back to three months forward — enough for the month/week grids and the
/// up-next list), and refreshes on the store's change notification plus a slow
/// poll. Flattens `EKEvent`s into value-type `CalendarEvent`s so nothing outside
/// here touches the store.
@MainActor
final class EventKitProvider: IslandContentProvider {
    let id = "com.dynamicisland.calendar"

    private weak var controller: DynamicIslandController?
    private let store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    /// How far back/forward to fetch. Back a little so "today" rows above the
    /// current time still show; forward enough to browse a few months.
    private let pastDays = 31
    private let futureDays = 93

    private var useMock: Bool {
        ProcessInfo.processInfo.environment["DI_MOCK_CALENDAR"] == "1"
    }

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        // The mock seed is installed by CalendarManager itself; don't touch the
        // real store (and don't trip the calendar TCC prompt) in that mode.
        guard !useMock else { return }

        requestAccess { [weak self] granted in
            guard let self else { return }
            self.controller?.calendarManager.setAuthorized(granted)
            guard granted else { return }
            self.refresh()

            self.storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: self.store, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }

            // Refetch periodically so events added on other devices (and the
            // rolling window) stay current even without a change notification.
            let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.pollTimer = timer
        }
    }

    func stopObserving() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
            self.storeObserver = nil
        }
    }

    // MARK: Access

    private func requestAccess(_ completion: @escaping (Bool) -> Void) {
        let handler: (Bool, Error?) -> Void = { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, error in handler(granted, error) }
        } else {
            store.requestAccess(to: .event) { granted, error in handler(granted, error) }
        }
    }

    // MARK: Fetch

    private func refresh() {
        let calendar = Calendar.current
        let now = Date()
        guard
            let start = calendar.date(byAdding: .day, value: -pastDays, to: calendar.startOfDay(for: now)),
            let end = calendar.date(byAdding: .day, value: futureDays, to: now)
        else { return }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = store.events(matching: predicate)
        let mapped = ekEvents.compactMap(Self.flatten)
        controller?.calendarManager.setEvents(mapped)
    }

    /// Flatten an `EKEvent` into our value type, deriving a stable id and a
    /// SwiftUI colour from the owning calendar.
    private static func flatten(_ event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let id = event.eventIdentifier ?? "\(event.calendarItemIdentifier)-\(start.timeIntervalSince1970)"
        let title = event.title?.isEmpty == false ? event.title! : "(No title)"
        let color: Color
        if let cg = event.calendar?.cgColor {
            color = Color(cgColor: cg)
        } else {
            color = Palette.blue
        }
        return CalendarEvent(
            id: id,
            title: title,
            location: event.location?.isEmpty == false ? event.location : nil,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            color: color)
    }
}
