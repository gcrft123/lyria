import SwiftUI

/// The compact, not-hovered Timers layout: the headline timer's icon, name, and
/// live value, with a faint progress glow along the bottom (countdowns only),
/// mirroring the compact music pill.
struct TimerCompactView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var timers: TimerManager

    private var accent: Color { IslandApp.timers.tint }

    var body: some View {
        let headline = timers.headline()
        HStack(spacing: Spacing.lg) {
            Image(systemName: headline?.kind == .stopwatch ? "stopwatch" : "timer")
                .font(.system(size: IconSize.lg, weight: .semibold))
                .foregroundStyle(headline?.hasFired == true ? .timerRing : accent)
                .frame(width: 22)

            Text(headline?.name ?? "Timers")
                .font(Typography.callout)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Spacing.md)

            if let headline {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let clock = formatClock(headline.displayValue(at: context.date))
                    Text(clock)
                        .font(Typography.headlineMono)
                        .foregroundStyle(Palette.textHigh)
                        .contentTransition(.numericText())
                        .animation(Motion.hover, value: clock)
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let headline, headline.kind == .countdown {
                progressGlow(headline)
            }
        }
    }

    private func progressGlow(_ timer: IslandTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            GeometryReader { geo in
                let width = geo.size.width * timer.fraction(at: context.date)
                ZStack(alignment: .bottomLeading) {
                    Capsule().fill(accent).frame(width: width, height: 3).blur(radius: 4).opacity(0.55)
                    Capsule().fill(accent.opacity(0.85)).frame(width: width, height: 1.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 8)
        }
        .frame(height: 8)
        .allowsHitTesting(false)
    }
}
