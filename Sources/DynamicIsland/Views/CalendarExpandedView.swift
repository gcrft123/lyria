import SwiftUI

/// The Calendar app filling the main island: a switchable month / week / day
/// navigator on the left and a scrolling "Up Next" agenda (events grouped by
/// day) on the right.
struct CalendarExpandedView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var calendar: CalendarManager

    enum ViewMode: String, CaseIterable, Identifiable {
        case month = "Month"
        case week = "Week"
        case day = "Day"
        var id: String { rawValue }
    }

    @State private var mode: ViewMode = {
        switch ProcessInfo.processInfo.environment["DI_CAL_MODE"]?.lowercased() {
        case "week": return .week
        case "day": return .day
        default: return .month
        }
    }()
    /// The day the navigator focuses on (selection in the grid, the day shown in
    /// Day view, the week shown in Week view). `DI_CAL_DAY=<int>` preselects a day
    /// offset from today (debug hook for verifying selection-driven behaviour).
    @State private var selectedDay: Date = {
        let base = Calendar.current.startOfDay(for: Date())
        if let raw = ProcessInfo.processInfo.environment["DI_CAL_DAY"], let offset = Int(raw) {
            return Calendar.current.date(byAdding: .day, value: offset, to: base) ?? base
        }
        return base
    }()

    private var accent: Color { IslandApp.calendar.tint }
    private var cal: Calendar { Calendar.current }
    private var config: IslandConfiguration { controller.configuration }

    var body: some View {
        VStack(spacing: Spacing.zero) {
            topBar
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.lg)
            Group {
                if mode == .week {
                    WeekTimeGridView(calendar: calendar, selectedDay: $selectedDay, accent: accent)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.xl)
                } else {
                    splitBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Top bar (full width)

    private var topBar: some View {
        HStack(spacing: Spacing.lg) {
            Text(headerTitle)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Spacing.md)
            navButton("chevron.left") { step(-1) }
            navButton("chevron.right") { step(1) }
            Button { withAnimation(Motion.transition) {
                selectedDay = cal.startOfDay(for: Date())
            } } label: {
                Text("Today")
                    .font(Typography.caption)
                    .foregroundStyle(accent)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: 26)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.island)
            modeSwitcher
                .frame(width: config.calendarModeSwitcherWidth)
        }
    }

    // MARK: Split body (Month / Day) — grid on the left, "Up Next" on the right

    private var splitBody: some View {
        HStack(spacing: Spacing.zero) {
            Group {
                switch mode {
                case .month: MonthGridView(calendar: calendar, selectedDay: $selectedDay, accent: accent)
                case .day:   DayDetailView(calendar: calendar, day: selectedDay, accent: accent)
                case .week:  EmptyView()
                }
            }
            .frame(width: config.calendarGridWidth)
            .padding(.horizontal, Spacing.xxl)
            .padding(.bottom, Spacing.xxl)
            .frame(maxHeight: .infinity, alignment: .top)
            Rectangle()
                .fill(Palette.hairlineStroke)
                .frame(width: 1)
                .padding(.vertical, Spacing.xs)
            rightPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        IconButton(system: symbol, weight: .bold) {
            withAnimation(Motion.transition) { action() }
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(ViewMode.allCases) { m in
                Button {
                    withAnimation(Motion.hover) { mode = m }
                } label: {
                    Text(m.rawValue)
                        .font(Typography.caption)
                        .foregroundStyle(mode == m ? Palette.onAccent : Palette.textHigh)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(
                            Capsule().fill(mode == m ? accent : Palette.surface)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.island)
            }
        }
    }

    /// Title reflecting the current mode + focused day.
    private var headerTitle: String {
        switch mode {
        case .month: return Self.monthYear.string(from: selectedDay)
        case .week:
            let interval = cal.dateInterval(of: .weekOfYear, for: selectedDay)
            let start = interval?.start ?? selectedDay
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? selectedDay
            return "\(Self.monthDay.string(from: start)) – \(Self.monthDay.string(from: end))"
        case .day: return Self.weekdayMonthDay.string(from: selectedDay)
        }
    }

    /// Step the focused day by one unit of the current mode.
    private func step(_ direction: Int) {
        let component: Calendar.Component
        switch mode {
        case .month: component = .month
        case .week: component = .weekOfYear
        case .day: component = .day
        }
        if let next = cal.date(byAdding: component, value: direction, to: selectedDay) {
            selectedDay = next
        }
    }

    // MARK: Right agenda

    /// In Month view the agenda follows the day selected in the grid (events from
    /// that day forward); elsewhere it tracks the present moment.
    private var agendaAnchor: Date {
        mode == .month ? cal.startOfDay(for: selectedDay) : Date()
    }

    private var agendaTitle: String {
        if mode == .month && !cal.isDateInToday(selectedDay) {
            return "From \(relativeDayLabel(selectedDay))"
        }
        return "Up Next"
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(agendaTitle)
                .font(Typography.headline)
                .foregroundStyle(Palette.textHigh)
                .lineLimit(1)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxl)

            let groups = calendar.upcomingGroupedByDay(from: agendaAnchor)
            if !calendar.authorized && calendar.events.isEmpty {
                emptyState("Calendar access needed", "Grant access in System Settings ▸ Privacy")
            } else if groups.isEmpty {
                emptyState("Nothing coming up", "Events appear here as they're added")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        ForEach(groups, id: \.day) { group in
                            agendaSection(group.day, group.events)
                        }
                    }
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.bottom, Spacing.xxl)
                }
            }
        }
    }

    private func agendaSection(_ day: Date, _ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(relativeDayLabel(day).uppercased())
                .font(Typography.caption)
                .foregroundStyle(accent.opacity(0.9))
                .tracking(0.5)
            ForEach(events) { event in
                AgendaRow(event: event)
            }
        }
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "calendar")
                .font(.system(size: IconSize.xxl, weight: .light))
                .foregroundStyle(Palette.textFaint)
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Text(subtitle)
                .font(Typography.footnote)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.xxl)
    }

    private func relativeDayLabel(_ day: Date) -> String {
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return Self.weekdayMonthDay.string(from: day)
    }

    // MARK: Formatters

    static let monthYear: DateFormatter = make("LLLL yyyy")
    static let monthDay: DateFormatter = make("MMM d")
    static let weekdayMonthDay: DateFormatter = make("EEE, MMM d")
    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.dateFormat = format; return f
    }
}

// MARK: - Agenda row

/// One event row in the right-hand up-next list: a colour bar, title + location,
/// and the time range.
private struct AgendaRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: Spacing.lg) {
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(event.color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(event.title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if let location = event.location {
                    Text(location)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.xs)
            Text(event.isAllDay ? "all-day" : event.startTimeText)
                .font(Typography.captionMono)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.lg)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Palette.surfaceSubtle))
    }
}

// MARK: - Month grid

private struct MonthGridView: View {
    @ObservedObject var calendar: CalendarManager
    @Binding var selectedDay: Date
    let accent: Color

    private var cal: Calendar { Calendar.current }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.xxs), count: 7)

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.xxs) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, sym in
                    Text(sym)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: Spacing.xs) {
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = cal.isDate(day, equalTo: selectedDay, toGranularity: .month)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let hasEvents = calendar.hasEvents(on: day)
        return Button {
            withAnimation(Motion.hover) {
                selectedDay = day
            }
        } label: {
            VStack(spacing: Spacing.xxs) {
                Text("\(cal.component(.day, from: day))")
                    .font(Typography.body)
                    .fontWeight(isToday ? .bold : .medium)
                    .foregroundStyle(cellTextColor(inMonth: inMonth, isToday: isToday, isSelected: isSelected))
                Circle()
                    .fill(hasEvents ? (isSelected ? Palette.textPrimary : accent) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(isSelected ? accent : (isToday ? Palette.surfaceRaised : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.island)
    }

    private func cellTextColor(inMonth: Bool, isToday: Bool, isSelected: Bool) -> Color {
        if isSelected { return Palette.onAccent }
        if isToday { return accent }
        return inMonth ? Palette.textHigh : Palette.textFaint
    }

    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// 42 days (6 weeks) covering the selected month, aligned to the week start.
    private var days: [Date] {
        guard
            let monthInterval = cal.dateInterval(of: .month, for: selectedDay),
            let gridStart = cal.dateInterval(of: .weekOfMonth, for: monthInterval.start)?.start
        else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }
}

// MARK: - Week time grid

/// One timed event after overlap packing: which sub-column it occupies and how
/// many sub-columns the overlapping cluster spans, so concurrent events tile
/// side-by-side instead of stacking on top of each other.
private struct PackedEvent {
    let event: CalendarEvent
    let column: Int
    let columnCount: Int
}

/// The week containing the selected day as a 7-column time grid (à la Apple
/// Calendar): a vertical hour axis on the left, a sticky day-header row, an
/// optional all-day row, and timed events overlaid as colour blocks positioned
/// by their start/end times.
private struct WeekTimeGridView: View {
    @ObservedObject var calendar: CalendarManager
    @Binding var selectedDay: Date
    let accent: Color

    private var cal: Calendar { Calendar.current }
    private let axisWidth: CGFloat = 44
    private let hourHeight: CGFloat = 40
    private let headerHeight: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let colW = (geo.size.width - axisWidth) / 7
            VStack(spacing: Spacing.zero) {
                dayHeaderRow(colW: colW)
                if hasAllDay { allDayRow(colW: colW) }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            // Hidden per-hour rows with real layout positions, so
                            // `scrollTo` can land on an hour. (`.offset` is only a
                            // render transform and wouldn't move the scroll target.)
                            VStack(spacing: Spacing.zero) {
                                ForEach(0..<24, id: \.self) { h in
                                    Color.clear.frame(height: hourHeight).id("hour-\(h)")
                                }
                            }
                            gridLines(colW: colW)
                            eventsLayer(colW: colW)
                            nowIndicator(colW: colW)
                        }
                        .frame(height: hourHeight * 24)
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("hour-\(scrollAnchorHour)", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    // MARK: Day header

    private func dayHeaderRow(colW: CGFloat) -> some View {
        HStack(spacing: Spacing.zero) {
            Color.clear.frame(width: axisWidth)
            ForEach(weekDays, id: \.self) { day in
                let isToday = cal.isDateInToday(day)
                let isSel = cal.isDate(day, inSameDayAs: selectedDay)
                Button {
                    withAnimation(Motion.hover) { selectedDay = day }
                } label: {
                    VStack(spacing: Spacing.xxs) {
                        Text(Self.weekdayAbbrev.string(from: day).uppercased())
                            .font(Typography.caption)
                            .foregroundStyle(isToday ? accent : Palette.textTertiary)
                        Text("\(cal.component(.day, from: day))")
                            .font(Typography.title2)
                            .fontWeight(isToday ? .bold : .medium)
                            .foregroundStyle(isToday ? Palette.onAccent : Palette.textHigh)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle().fill(isToday ? accent : (isSel ? Palette.surfaceStrong : .clear))
                            )
                    }
                    .frame(width: colW, height: headerHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.island)
            }
        }
        .frame(height: headerHeight)
    }

    // MARK: All-day row

    private var allDayEventsByDay: [[CalendarEvent]] {
        weekDays.map { day in calendar.events(on: day).filter { $0.isAllDay } }
    }
    private var hasAllDay: Bool { allDayEventsByDay.contains { !$0.isEmpty } }

    private func allDayRow(colW: CGFloat) -> some View {
        HStack(spacing: Spacing.zero) {
            Text("all-day")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: axisWidth - 4, alignment: .trailing)
                .padding(.trailing, Spacing.xs)
            ForEach(Array(weekDays.enumerated()), id: \.element) { idx, _ in
                VStack(spacing: Spacing.xxs) {
                    ForEach(allDayEventsByDay[idx]) { ev in
                        Text(ev.title)
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(ev.color.opacity(0.55)))
                    }
                }
                .frame(width: colW)
                .padding(.horizontal, Spacing.hairline)
            }
        }
        .padding(.vertical, Spacing.xs)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairlineStroke).frame(height: 1)
        }
    }

    // MARK: Grid lines + hour axis

    private func gridLines(colW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...24, id: \.self) { hour in
                Rectangle()
                    .fill(Palette.surfaceSubtle)
                    .frame(height: 1)
                    .offset(y: CGFloat(hour) * hourHeight)
                if hour < 24 {
                    Text(hourLabel(hour))
                        .font(Typography.footnoteMono)
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: axisWidth - 6, alignment: .trailing)
                        .offset(x: 0, y: CGFloat(hour) * hourHeight + 2)
                }
            }
            ForEach(0...7, id: \.self) { i in
                Rectangle()
                    .fill(Palette.surfaceSubtle)
                    .frame(width: 1, height: hourHeight * 24)
                    .offset(x: axisWidth + CGFloat(i) * colW)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12)\(hour < 12 ? "a" : "p")"
    }

    // MARK: Timed events

    private func eventsLayer(colW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(weekDays.enumerated()), id: \.element) { idx, day in
                ForEach(packedEvents(on: day), id: \.event.id) { item in
                    eventBlock(item, dayIndex: idx, colW: colW, day: day)
                }
            }
        }
    }

    private func eventBlock(_ item: PackedEvent, dayIndex: Int, colW: CGFloat, day: Date) -> some View {
        let dayStart = cal.startOfDay(for: day)
        let startHours = max(0, item.event.start.timeIntervalSince(dayStart) / 3600)
        let endHours = min(24, item.event.end.timeIntervalSince(dayStart) / 3600)
        let y = CGFloat(startHours) * hourHeight
        let h = max(20, CGFloat(endHours - startHours) * hourHeight)
        let subW = colW / CGFloat(item.columnCount)
        let x = axisWidth + CGFloat(dayIndex) * colW + CGFloat(item.column) * subW
        return eventBlockBody(item.event, height: h)
            .frame(width: max(2, subW - 2), height: max(2, h - 1), alignment: .topLeading)
            .offset(x: x + 1, y: y)
    }

    private func eventBlockBody(_ event: CalendarEvent, height: CGFloat) -> some View {
        HStack(spacing: Spacing.zero) {
            RoundedRectangle(cornerRadius: Radius.xs).fill(event.color).frame(width: 3)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(event.title)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(height > 58 ? 2 : 1)
                if height > 40 {
                    Text(event.startTimeText)
                        .font(Typography.footnoteMono)
                        .foregroundStyle(Palette.textHigh)
                }
            }
            .padding(.leading, Spacing.sm)
            .padding(.trailing, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(event.color.opacity(0.26)))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    /// Greedy overlap packing: events are clustered by overlap, and within each
    /// cluster every event is placed in the first column whose previous event has
    /// already ended, returning each event's column index and the cluster width.
    private func packedEvents(on day: Date) -> [PackedEvent] {
        let timed = calendar.events(on: day)
            .filter { !$0.isAllDay }
            .sorted { $0.start < $1.start }
        guard !timed.isEmpty else { return [] }

        var result: [PackedEvent] = []
        var cluster: [CalendarEvent] = []
        var clusterEnd: Date? = nil

        func flush() {
            guard !cluster.isEmpty else { return }
            var columnEnds: [Date] = []
            var assignment: [(CalendarEvent, Int)] = []
            for ev in cluster {
                var placed = false
                for c in columnEnds.indices where columnEnds[c] <= ev.start {
                    columnEnds[c] = ev.end
                    assignment.append((ev, c))
                    placed = true
                    break
                }
                if !placed {
                    columnEnds.append(ev.end)
                    assignment.append((ev, columnEnds.count - 1))
                }
            }
            let count = columnEnds.count
            for (ev, col) in assignment {
                result.append(PackedEvent(event: ev, column: col, columnCount: count))
            }
            cluster.removeAll()
            clusterEnd = nil
        }

        for ev in timed {
            if let end = clusterEnd, ev.start >= end { flush() }
            cluster.append(ev)
            clusterEnd = Swift.max(clusterEnd ?? ev.end, ev.end)
        }
        flush()
        return result
    }

    // MARK: Now indicator

    @ViewBuilder
    private func nowIndicator(colW: CGFloat) -> some View {
        let now = Date()
        if let idx = weekDays.firstIndex(where: { cal.isDateInToday($0) }) {
            let dayStart = cal.startOfDay(for: now)
            let y = CGFloat(now.timeIntervalSince(dayStart) / 3600) * hourHeight
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Palette.red)
                    .frame(width: colW, height: 1)
                    .offset(x: axisWidth + CGFloat(idx) * colW, y: y)
                Circle()
                    .fill(Palette.red)
                    .frame(width: 5, height: 5)
                    .offset(x: axisWidth + CGFloat(idx) * colW - 2, y: y - 2)
            }
        }
    }

    private var weekDays: [Date] {
        let start = cal.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? selectedDay
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Where the grid scrolls to on appear: an hour-or-so before "now" when the
    /// displayed week includes today (so the now-line and current events are in
    /// view, like Apple Calendar), otherwise the start of the working day.
    private var scrollAnchorHour: Int {
        if weekDays.contains(where: { cal.isDateInToday($0) }) {
            let hours = Date().timeIntervalSince(cal.startOfDay(for: Date())) / 3600
            return max(0, Int(hours) - 2)
        }
        return 7
    }

    static let weekdayAbbrev: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
}

// MARK: - Day detail

/// A single day's events as larger cards with time range and location.
private struct DayDetailView: View {
    @ObservedObject var calendar: CalendarManager
    let day: Date
    let accent: Color

    private var cal: Calendar { Calendar.current }

    var body: some View {
        let events = calendar.events(on: day)
        ScrollView(.vertical, showsIndicators: false) {
            if events.isEmpty {
                Text("No events")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, Spacing.xxxxl)
            } else {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(events) { event in
                        HStack(spacing: Spacing.lg) {
                            VStack(spacing: Spacing.xxs) {
                                Text(event.isAllDay ? "all" : Self.hm.string(from: event.start))
                                    .font(Typography.bodyMono)
                                    .foregroundStyle(Palette.textPrimary)
                                if !event.isAllDay {
                                    Text(Self.hm.string(from: event.end))
                                        .font(Typography.footnoteMono)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                            .frame(width: 52, alignment: .leading)
                            RoundedRectangle(cornerRadius: Radius.xs).fill(event.color).frame(width: 3)
                            VStack(alignment: .leading, spacing: Spacing.hairline) {
                                Text(event.title)
                                    .font(Typography.body)
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                                if let location = event.location {
                                    Text(location)
                                        .font(Typography.footnote)
                                        .foregroundStyle(Palette.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: Spacing.xxs)
                        }
                        .padding(.vertical, Spacing.md)
                        .padding(.horizontal, Spacing.lg)
                        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Palette.surfaceSubtle))
                    }
                }
            }
        }
    }

    static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm"; return f
    }()
}
