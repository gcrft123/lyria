import SwiftUI

/// The compact, not-hovered now-playing layout: artwork on the left, song /
/// artist in the centre (where the iPhone's camera would be), animated bars on
/// the right. A faint accent-coloured glow runs along the bottom edge and
/// fills left-to-right with the track's playback position.
struct CompactPlayerView: View {
    @ObservedObject var controller: DynamicIslandController
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if let nowPlaying = controller.nowPlaying {
            let accent = settings.accent(for: nowPlaying)

            HStack(spacing: Spacing.md) {
                ArtworkView(image: nowPlaying.artwork, size: 30, cornerRadius: Radius.md)

                Spacer(minLength: Spacing.md)

                VStack(spacing: Spacing.hairline) {
                    Text(nowPlaying.title)
                        .font(Typography.calloutStrong)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(nowPlaying.artist)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Spacing.md)

                if settings.showEqualizerBars {
                    NowPlayingBars(color: accent, isPlaying: nowPlaying.isPlaying)
                        .frame(width: 18)
                } else {
                    Color.clear.frame(width: 18)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if settings.showCompactGlow {
                    progressGlow(nowPlaying, accent: accent)
                }
            }
        }
    }

    /// A thin accent line along the bottom edge that fills across the pill as
    /// the track plays. A blurred copy underneath provides the glow; a crisper
    /// core sits on top. The parent's `clipShape` trims it to the pill, so the
    /// fill emerges from the rounded left end and follows the bottom curve.
    private func progressGlow(_ nowPlaying: NowPlaying, accent: Color) -> some View {
        let intensity = settings.glowIntensity
        return TimelineView(.periodic(from: .now, by: 0.2)) { context in
            GeometryReader { geo in
                let fraction = nowPlaying.duration > 0
                    ? min(1, max(0, nowPlaying.currentElapsed(at: context.date) / nowPlaying.duration))
                    : 0
                let width = geo.size.width * fraction

                ZStack(alignment: .bottomLeading) {
                    Capsule()
                        .fill(accent)
                        .frame(width: width, height: 3)
                        .blur(radius: 4)
                        .opacity(0.55 * intensity)
                    Capsule()
                        .fill(accent.opacity(0.4 + 0.5 * intensity))
                        .frame(width: width, height: 1.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 8)
        }
        .frame(height: 8)
        .allowsHitTesting(false)
    }
}
