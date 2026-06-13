import SwiftUI

/// The compact, not-hovered Calendar layout: the live activity for an event
/// starting in under 15 minutes. A circular ring depletes as the start
/// approaches, beside the event title and a "in N min" countdown.
struct CalendarCompactView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var calendar: CalendarManager

    private var accent: Color { IslandApp.calendar.tint }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            if let event = calendar.imminentEvent(at: now) {
                content(for: event, at: now)
            } else {
                // Between the imminence flip and the next layout pass there can be
                // a frame with no event; keep the pill from collapsing oddly.
                placeholder
            }
        }
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for event: CalendarEvent, at now: Date) -> some View {
        let remaining = max(0, event.timeUntilStart(at: now))
        // Ring fills toward the start: full circle at 15 min out → empty at start.
        let fraction = min(1, max(0, remaining / calendar.imminentWindow))
        return HStack(spacing: Spacing.xl) {
            ring(fraction: fraction, accent: eventTint(event))

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(event.title)
                    .font(Typography.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(countdownText(remaining))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.xs)

            Text(event.startTimeText)
                .font(Typography.calloutMono)
                .foregroundStyle(eventTint(event))
                .lineLimit(1)
        }
    }

    private var placeholder: some View {
        HStack(spacing: Spacing.xl) {
            ring(fraction: 1, accent: accent)
            Text("Calendar")
                .font(Typography.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: Spacing.xs)
        }
    }

    private func ring(fraction: Double, accent: Color) -> some View {
        ZStack {
            Circle()
                .stroke(Palette.surfaceStrong, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(fraction))
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "calendar")
                .font(.system(size: IconSize.xs, weight: .bold))
                .foregroundStyle(accent)
        }
        .frame(width: 26, height: 26)
        .animation(Motion.gentle, value: fraction)
    }

    private func eventTint(_ event: CalendarEvent) -> Color {
        // Calendar colours can be near-black/low-contrast on the island; fall back
        // to the app accent when the event's own colour reads too dark.
        event.color
    }

    /// "in 12 min", "in 1 min", or "now" near zero.
    private func countdownText(_ remaining: TimeInterval) -> String {
        let mins = Int((remaining / 60).rounded(.up))
        if remaining <= 30 { return "starting now" }
        if mins <= 1 { return "in 1 min" }
        return "in \(mins) min"
    }
}
