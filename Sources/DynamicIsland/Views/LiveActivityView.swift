import SwiftUI

/// The compact, glanceable live-activity pill (e.g. the onboarding "open me"
/// hint) — a leading glyph, a short line, and a gently bobbing chevron cueing
/// that the island opens. Non-blocking: hovering / clicking / scrolling it still
/// expands the island.
struct LiveActivityView: View {
    let activity: LiveActivity

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: activity.symbol)
                .font(.system(size: IconSize.lg, weight: .semibold))
                .foregroundStyle(activity.accent)
            Text(activity.title)
                .font(Typography.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            TimelineView(.animation) { context in
                let bob = CGFloat(2 + 2 * sin(context.date.timeIntervalSinceReferenceDate * 3))
                Image(systemName: "chevron.down")
                    .font(.system(size: IconSize.sm, weight: .bold))
                    .foregroundStyle(activity.accent.opacity(0.85))
                    .offset(y: bob)
            }
            .frame(width: 12, height: 16)
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
