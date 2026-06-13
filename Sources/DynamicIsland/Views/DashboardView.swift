import AppKit
import SwiftUI

/// The Dashboard app: an at-a-glance "home" aggregating smaller counterparts of
/// the other apps. Compressed to the shared app height (324). Layout prototypes
/// are selectable with `DI_DASH_PROTO=1…5` while we pick one:
///
///   1 — Tight quadrants     (the classic 2×2, just denser)
///   2 — Hero + strip        (big player on top, thin calendar+weather strip)
///   3 — Player + side column (full player left, calendar/weather stacked right)
///   4 — Compact list        (no cards — a stacked widget list)
///   5 — Music mirror        (the exact Music layout — full player left, with the
///                            queue sidebar replaced by Calendar stacked on Weather)
struct DashboardView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var timers: TimerManager
    @ObservedObject var calendar: CalendarManager
    @ObservedObject var weather: WeatherManager

    // Proto 5 (Music mirror) is the chosen layout and the default; the earlier
    // prototypes stay reachable via DI_DASH_PROTO=1…4 for comparison.
    private var proto: Int { Int(ProcessInfo.processInfo.environment["DI_DASH_PROTO"] ?? "") ?? 5 }
    private var musicTint: Color {
        controller.nowPlaying.map { controller.settings.accent(for: $0) } ?? AppSettings.neutralAccent
    }

    var body: some View {
        Group {
            switch proto {
            case 2: heroStrip
            case 3: playerColumn
            case 4: compactList
            case 5: musicMirror
            default: quadrants
            }
        }
        .padding(.horizontal, outerInset)
        .padding(.vertical, outerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Proto 5 mirrors the Music app's own margins, so the Dashboard's outer
    /// gutter is dropped for it; every other proto uses the standard inset.
    private var outerInset: CGFloat { isMirror ? Spacing.zero : Spacing.xl }
    private var isMirror: Bool { proto == 5 }

    // MARK: Proto 1 — tight quadrants

    private var quadrants: some View {
        VStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                musicCard { MusicMini(controller: controller, tint: musicTint, compact: true) }
                if timers.hasActive {
                    DashCard(title: "Timers", icon: "timer", tint: IslandApp.timers.tint,
                             onOpen: { controller.selectApp(.timers) }) { TimersMini(timers: timers) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: Spacing.md) {
                calendarCard { CalendarMini(calendar: calendar, limit: 3) }
                weatherCard { WeatherMini(weather: weather, showHourly: true) }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Proto 2 — hero player + bottom strip

    private var heroStrip: some View {
        VStack(spacing: Spacing.md) {
            musicCard { MusicMini(controller: controller, tint: musicTint, compact: true) }
                .frame(maxHeight: .infinity)
            HStack(spacing: Spacing.md) {
                calendarCard { CalendarMini(calendar: calendar, limit: 2) }
                weatherCard { WeatherMini(weather: weather, showHourly: false) }
            }
            .frame(height: 92)
        }
    }

    // MARK: Proto 3 — full player + side column

    private var playerColumn: some View {
        HStack(spacing: Spacing.md) {
            musicCard { MusicMini(controller: controller, tint: musicTint, compact: false) }
                .frame(width: 270) // design-lint:allow — throwaway prototype geometry (proto 3, not the chosen layout)
            VStack(spacing: Spacing.md) {
                calendarCard { CalendarMini(calendar: calendar, limit: 2) }
                weatherCard { WeatherMini(weather: weather, showHourly: false) }
            }
        }
    }

    // MARK: Proto 4 — compact list

    private var compactList: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            listHeader("Music", icon: "music.note", tint: musicTint) { controller.selectApp(.music) }
            MusicRow(controller: controller, tint: musicTint)

            divider
            listHeader("Up Next", icon: "calendar", tint: IslandApp.calendar.tint) { controller.selectApp(.calendar) }
            CalendarMini(calendar: calendar, limit: 3)

            divider
            listHeader("Weather", icon: "cloud.sun.fill", tint: IslandApp.weather.tint) { controller.selectApp(.weather) }
            WeatherRow(weather: weather)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairlineStroke).frame(height: 1)
    }

    private func listHeader(_ title: String, icon: String, tint: Color, onOpen: @escaping () -> Void) -> some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon).font(.system(size: IconSize.xs, weight: .semibold)).foregroundStyle(tint)
                Text(title.uppercased()).font(Typography.caption).foregroundStyle(Palette.textSecondary).kerning(0.5)
                Spacer(minLength: Spacing.xxs)
                Image(systemName: "chevron.right").font(.system(size: IconSize.xs, weight: .bold)).foregroundStyle(Palette.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.islandFlat)
    }

    // MARK: Proto 5 — Music mirror (player left, Calendar/Weather replace the queue)

    private var musicMirror: some View {
        HStack(spacing: Spacing.zero) {
            // The SHARED player column (no volume control on the dashboard), so it
            // is byte-for-byte the same as the real Music app and can't drift.
            MusicPlayerColumn(controller: controller, showsVolume: false)
                .frame(width: config.musicPlayerWidth)

            // The 1px divider in the same place the Music app draws it.
            Rectangle()
                .fill(Palette.hairlineStroke)
                .frame(width: 1)
                .padding(.vertical, Spacing.lg)

            // Calendar stacked on Weather, where the queue sidebar normally sits.
            VStack(spacing: Spacing.zero) {
                sidebarSection("Up Next", icon: "calendar", tint: IslandApp.calendar.tint,
                               onOpen: { controller.selectApp(.calendar) }) {
                    MirrorCalendarList(calendar: calendar)
                }
                Rectangle().fill(Palette.hairlineStroke).frame(height: 1).padding(.horizontal, Spacing.xxl)
                sidebarSection("Weather", icon: "cloud.sun.fill", tint: IslandApp.weather.tint,
                               onOpen: { controller.selectApp(.weather) }) {
                    MirrorWeatherSummary(weather: weather)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .buttonStyle(.island)
    }

    private var config: IslandConfiguration { controller.configuration }

    /// A queue-sidebar-style section: a tappable tinted header over its widget,
    /// filling its share of the right column. Trailing inset keeps content clear
    /// of the card's rounded corner.
    private func sidebarSection<C: View>(_ title: String, icon: String, tint: Color,
                                         onOpen: @escaping () -> Void,
                                         @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: icon).font(.system(size: IconSize.xs, weight: .semibold)).foregroundStyle(tint)
                    Text(title).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: Spacing.xxs)
                    Image(systemName: "chevron.right").font(.system(size: IconSize.xs, weight: .bold)).foregroundStyle(Palette.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.islandFlat)
            content()
            Spacer(minLength: Spacing.zero)
        }
        .padding(.leading, Spacing.xxl)
        .padding(.trailing, Spacing.xl)
        .padding(.vertical, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Card helpers

    private func musicCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        DashCard(title: "Music", icon: "music.note", tint: musicTint,
                 onOpen: { controller.selectApp(.music) }, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func calendarCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        DashCard(title: "Up Next", icon: "calendar", tint: IslandApp.calendar.tint,
                 onOpen: { controller.selectApp(.calendar) }, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func weatherCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        DashCard(title: "Weather", icon: "cloud.sun.fill", tint: IslandApp.weather.tint,
                 onOpen: { controller.selectApp(.weather) }, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card container

private struct DashCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let onOpen: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: icon).font(.system(size: IconSize.xs, weight: .semibold)).foregroundStyle(tint)
                    Text(title).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: Spacing.xxs)
                    Image(systemName: "chevron.right").font(.system(size: IconSize.xs, weight: .bold)).foregroundStyle(Palette.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.islandFlat)

            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Narrow sidebar widgets (proto 5 right column)

/// Calendar list sized for the narrow queue column: two-line rows (title over
/// time) so nothing crowds the card's right edge.
private struct MirrorCalendarList: View {
    @ObservedObject var calendar: CalendarManager
    var limit: Int = 3
    private var cal: Calendar { Calendar.current }

    var body: some View {
        let events = Array(calendar.upcoming().prefix(limit))
        if events.isEmpty {
            DashEmpty(symbol: "calendar", text: "Nothing coming up")
        } else {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ForEach(events) { event in
                    HStack(spacing: Spacing.sm) {
                        RoundedRectangle(cornerRadius: Radius.xs).fill(event.color).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(event.title).font(Typography.caption).foregroundStyle(Palette.textPrimary).lineLimit(1)
                            Text(whenText(event)).font(Typography.captionMono).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func whenText(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "all-day" }
        if cal.isDateInToday(event.start) { return event.startTimeText }
        return Self.weekday.string(from: event.start) + " " + event.startTimeText
    }
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
}

/// Compact weather summary sized for the narrow column: location · big temp ·
/// condition · H/L stacked on the left, condition glyph top-right.
private struct MirrorWeatherSummary: View {
    @ObservedObject var weather: WeatherManager
    var body: some View {
        if let snap = weather.snapshot {
            HStack(alignment: .top, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(snap.locationName).font(Typography.caption).foregroundStyle(Palette.textHigh).lineLimit(1)
                    Text(WeatherFormat.temp(snap.temperature))
                        .font(.system(size: 30, weight: .thin)) // design-lint:allow — mini hero temperature numeral
                        .monospacedDigit().foregroundStyle(Palette.textPrimary)
                    Text(snap.condition.description).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    Text("H:\(WeatherFormat.temp(snap.high))  L:\(WeatherFormat.temp(snap.low))")
                        .font(Typography.captionMono).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
                Spacer(minLength: Spacing.xxs)
                Image(systemName: snap.condition.symbol).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.textHigh).font(.system(size: IconSize.xxl))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            DashEmpty(symbol: "cloud.sun.fill", text: "Getting weather…")
        }
    }
}

// MARK: - Music mini (compact = 3 rows, full = 4 rows)

private struct MusicMini: View {
    @ObservedObject var controller: DynamicIslandController
    let tint: Color
    var compact: Bool = false
    @State private var seekHovered = false
    private var settings: AppSettings { controller.settings }

    var body: some View {
        if let np = controller.nowPlaying {
            VStack(spacing: Spacing.sm) {
                topRow(np)
                progressRow(np)
                transportRow(np)
                if !compact { bottomRow(np) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .buttonStyle(.island)
        } else {
            DashEmpty(symbol: "music.note", text: "Nothing Playing")
        }
    }

    private func topRow(_ np: NowPlaying) -> some View {
        let art: CGFloat = compact ? 38 : 42
        return HStack(spacing: Spacing.lg) {
            ArtworkView(image: np.artwork, size: art, cornerRadius: Radius.md)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(np.title).font(Typography.subheadline).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    .contentShape(Rectangle()).onTapGesture { controller.openSongPage() }
                Text(np.artist).font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    .contentShape(Rectangle()).onTapGesture { controller.openArtistPage() }
            }
            Spacer(minLength: Spacing.md)
            FavoriteButton(isFavorited: np.isFavorited, size: IconSize.lg) { controller.toggleFavorite() }
            if settings.showEqualizerBars {
                NowPlayingBars(color: tint, isPlaying: np.isPlaying, maxHeight: 14).frame(width: 18)
            }
        }
        .frame(height: art)
    }

    private func progressRow(_ np: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let elapsed = np.currentElapsed(at: context.date)
            let remaining = max(0, np.duration - elapsed)
            VStack(spacing: Spacing.xs) {
                ProgressBarView(elapsed: elapsed, duration: np.duration, accent: tint,
                                isHovered: seekHovered, onCommit: { controller.seek(to: $0) })
                    .onHover { seekHovered = $0 }
                let elapsedText = formatTime(elapsed)
                HStack {
                    Text(elapsedText).contentTransition(.numericText())
                    Spacer()
                    Text("-" + formatTime(remaining)).contentTransition(.numericText())
                }
                .font(Typography.footnoteMono)
                .foregroundStyle(Palette.textSecondary)
                .animation(Motion.hover, value: elapsedText)
            }
        }
        .frame(height: compact ? 22 : 26)
    }

    private func transportRow(_ np: NowPlaying) -> some View {
        HStack(spacing: Spacing.xxl) {
            transportButton("backward.fill", glyphSize: IconSize.lg) { controller.previousTrack() }
            transportButton(np.isPlaying ? "pause.fill" : "play.fill", glyphSize: IconSize.xxl) { controller.playPause() }
            transportButton("forward.fill", glyphSize: IconSize.lg) { controller.nextTrack() }
        }
        .foregroundStyle(Palette.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 28 : 30)
    }

    private func bottomRow(_ np: NowPlaying) -> some View {
        HStack(spacing: 0) {
            Button(action: { controller.toggleShuffle() }) {
                Image(systemName: "shuffle")
                    .foregroundStyle(np.shuffle ? tint : Palette.textSecondary)
                    .frame(width: 44, height: 22, alignment: .leading).contentShape(Rectangle())
            }
            Spacer()
            AirPlayButton(activeTint: NSColor(tint)).frame(width: 24, height: 24)
            Spacer()
            Button(action: { controller.cycleRepeat() }) {
                Image(systemName: np.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(np.repeatMode == .off ? Palette.textSecondary : tint)
                    .frame(width: 44, height: 22, alignment: .trailing).contentShape(Rectangle())
            }
        }
        .font(.system(size: IconSize.md, weight: .semibold))
        .frame(height: 22)
    }

    private func transportButton(_ symbol: String, glyphSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: glyphSize)).frame(width: 46, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.islandSubtle)
    }
}

// MARK: - Music row (single line, for the list proto)

private struct MusicRow: View {
    @ObservedObject var controller: DynamicIslandController
    let tint: Color

    var body: some View {
        if let np = controller.nowPlaying {
            HStack(spacing: Spacing.lg) {
                ArtworkView(image: np.artwork, size: 36, cornerRadius: Radius.md)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(np.title).font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    Text(np.artist).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Spacer(minLength: Spacing.md)
                Button { controller.previousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: IconSize.md)).frame(width: 30, height: 28).contentShape(Rectangle())
                }.buttonStyle(.islandSubtle)
                Button { controller.playPause() } label: {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill").font(.system(size: IconSize.xl)).frame(width: 32, height: 28).contentShape(Rectangle())
                }.buttonStyle(.islandSubtle)
                Button { controller.nextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: IconSize.md)).frame(width: 30, height: 28).contentShape(Rectangle())
                }.buttonStyle(.islandSubtle)
            }
            .foregroundStyle(Palette.textPrimary)
        } else {
            DashEmpty(symbol: "music.note", text: "Nothing Playing")
        }
    }
}

// MARK: - Timers mini

private struct TimersMini: View {
    @ObservedObject var timers: TimerManager
    var body: some View {
        let ordered = timers.ordered()
        let shown = Array(ordered.prefix(3))
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(shown) { row($0) }
            if ordered.count > shown.count {
                Text("+\(ordered.count - shown.count) more").font(Typography.footnote).foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ timer: IslandTimer) -> some View {
        let tint: Color = timer.hasFired ? .timerRing : IslandApp.timers.tint
        return HStack(spacing: Spacing.md) {
            Image(systemName: timer.kind == .countdown ? "timer" : "stopwatch")
                .font(.system(size: IconSize.sm, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.name).font(Typography.caption).foregroundStyle(Palette.textPrimary).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let clock = formatClock(timer.displayValue(at: context.date))
                    Text(clock).font(Typography.calloutMono)
                        .foregroundStyle(timer.hasFired ? tint : Palette.textHigh)
                        .contentTransition(.numericText()).animation(Motion.hover, value: clock)
                }
            }
            Spacer(minLength: Spacing.xs)
            if !timer.hasFired {
                Button { timers.toggleRun(timer.id) } label: {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: IconSize.xs, weight: .semibold)).foregroundStyle(Palette.textHigh)
                        .frame(width: 24, height: 24).background(Circle().fill(Palette.surface)).contentShape(Circle())
                }.buttonStyle(.island)
            }
        }
    }
}

// MARK: - Calendar mini

private struct CalendarMini: View {
    @ObservedObject var calendar: CalendarManager
    var limit: Int = 4
    private var cal: Calendar { Calendar.current }

    var body: some View {
        let events = Array(calendar.upcoming().prefix(limit))
        if events.isEmpty {
            DashEmpty(symbol: "calendar", text: "Nothing coming up")
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(events) { event in
                    HStack(spacing: Spacing.sm) {
                        RoundedRectangle(cornerRadius: Radius.xs).fill(event.color).frame(width: 3, height: 22)
                        Text(event.title).font(Typography.caption).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Spacer(minLength: Spacing.xs)
                        Text(whenText(event)).font(Typography.captionMono).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func whenText(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "all-day" }
        if cal.isDateInToday(event.start) { return event.startTimeText }
        return Self.weekday.string(from: event.start) + " " + event.startTimeText
    }
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
}

// MARK: - Weather mini & row

private struct WeatherMini: View {
    @ObservedObject var weather: WeatherManager
    var showHourly: Bool = true

    var body: some View {
        if let snap = weather.snapshot {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(snap.locationName).font(Typography.caption).foregroundStyle(Palette.textHigh).lineLimit(1)
                        Text(WeatherFormat.temp(snap.temperature))
                            .font(.system(size: 28, weight: .thin)) // design-lint:allow — mini hero temperature numeral
                            .monospacedDigit().foregroundStyle(Palette.textPrimary)
                        Text(snap.condition.description).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.xxs)
                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        Image(systemName: snap.condition.symbol).symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Palette.textHigh).font(.system(size: IconSize.xl))
                        Text("H:\(WeatherFormat.temp(snap.high))  L:\(WeatherFormat.temp(snap.low))")
                            .font(Typography.captionMono).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                if showHourly {
                    Spacer(minLength: Spacing.xs)
                    hourly(snap)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            DashEmpty(symbol: "cloud.sun.fill", text: "Getting weather…")
        }
    }

    private func hourly(_ snap: WeatherSnapshot) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(snap.hourly.prefix(5))) { h in
                VStack(spacing: Spacing.xs) {
                    Text(WeatherFormat.hour(h.date, in: snap.timeZone, now: h.isNow))
                        .font(Typography.footnote).foregroundStyle(h.isNow ? Palette.textPrimary : Palette.textSecondary)
                    Image(systemName: h.condition.symbol).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Palette.textHigh).font(.system(size: IconSize.md)).frame(height: 16)
                    Text(WeatherFormat.temp(h.temperature)).font(Typography.captionMono).foregroundStyle(Palette.textPrimary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One-line weather (glyph · temp · condition · H/L) for the list proto.
private struct WeatherRow: View {
    @ObservedObject var weather: WeatherManager
    var body: some View {
        if let snap = weather.snapshot {
            HStack(spacing: Spacing.md) {
                Image(systemName: snap.condition.symbol).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.textHigh).font(.system(size: IconSize.xl)).frame(width: 26)
                Text(WeatherFormat.temp(snap.temperature)).font(Typography.title2).foregroundStyle(Palette.textPrimary).monospacedDigit()
                VStack(alignment: .leading, spacing: 0) {
                    Text(snap.condition.description).font(Typography.caption).foregroundStyle(Palette.textHigh).lineLimit(1)
                    Text(snap.locationName).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                Text("H:\(WeatherFormat.temp(snap.high))  L:\(WeatherFormat.temp(snap.low))")
                    .font(Typography.captionMono).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
        } else {
            DashEmpty(symbol: "cloud.sun.fill", text: "Getting weather…")
        }
    }
}

// MARK: - Shared empty state

private struct DashEmpty: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                .font(.system(size: IconSize.xl)).foregroundStyle(Palette.textFaint)
            Text(text).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Compact pill

/// The compact dashboard pill (only via `DI_FORCE_APP=dashboard`).
struct DashboardCompactView: View {
    @ObservedObject var controller: DynamicIslandController
    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: IconSize.lg)).foregroundStyle(IslandApp.dashboard.tint)
            Text("Dashboard").font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
            Spacer(minLength: Spacing.sm)
            Image(systemName: "chevron.down").font(.system(size: IconSize.sm, weight: .bold)).foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
