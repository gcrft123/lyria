import SwiftUI

/// The shrunken Now Playing player shown on the Search/Library tabs: a floating
/// liquid-glass **capsule** mirroring the closed island's music preview — artwork +
/// title/artist (tap to open Now Playing) and the favorite · transport · more
/// cluster, with the track position shown as the same accent glow line that runs
/// along the bottom edge of `CompactPlayerView` (no separate seek-bar row).
struct MiniPlayerPill: View {
    @ObservedObject var controller: DynamicIslandController
    let onTap: () -> Void

    private var accent: Color {
        controller.nowPlaying.map { controller.settings.accent(for: $0) } ?? Palette.neutralAccent
    }

    var body: some View {
        if let np = controller.nowPlaying {
            HStack(spacing: Spacing.md) {
                // The art + text region opens Now Playing; the controls don't.
                HStack(spacing: Spacing.md) {
                    ArtworkView(image: np.artwork, size: 30, cornerRadius: Radius.sm)
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(np.title).font(Typography.caption).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Text(np.artist).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

                Spacer(minLength: Spacing.sm)

                FavoriteButton(isFavorited: np.isFavorited, size: IconSize.md) { controller.toggleFavorite() }
                iconButton("backward.fill", glyph: IconSize.md) { controller.previousTrack() }
                iconButton(np.isPlaying ? "pause.fill" : "play.fill", glyph: IconSize.lg) { controller.playPause() }
                iconButton("forward.fill", glyph: IconSize.md) { controller.nextTrack() }
                moreMenu(np)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(GlassPill())
            .overlay(alignment: .bottom) { progressGlow(np) }
            .clipShape(Capsule(style: .continuous))
        }
    }

    private func iconButton(_ symbol: String, glyph: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.islandSubtle)
    }

    private func moreMenu(_ np: NowPlaying) -> some View {
        Menu {
            Button { controller.toggleFavorite() } label: {
                Label(np.isFavorited ? "Unfavorite" : "Favorite",
                      systemImage: np.isFavorited ? "heart.slash" : "heart")
            }
            Button { controller.toggleShuffle() } label: { Label("Shuffle", systemImage: "shuffle") }
            Button { controller.openSongPage() } label: { Label("Open in Apple Music", systemImage: "arrow.up.forward.app") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: IconSize.md, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
    }

    /// The track-position seek line along the pill's bottom edge — the same accent
    /// glow the closed-island music preview uses (`CompactPlayerView.progressGlow`):
    /// a blurred under-layer plus a crisp core that fills left→right as the song
    /// plays. The capsule clip trims it so it emerges from the rounded left end and
    /// follows the bottom curve. Display-only (no scrubbing), advanced live between
    /// polls via `currentElapsed`.
    private func progressGlow(_ np: NowPlaying) -> some View {
        let intensity = controller.settings.glowIntensity
        return TimelineView(.periodic(from: .now, by: 0.2)) { context in
            GeometryReader { geo in
                let fraction = np.duration > 0
                    ? min(1, max(0, np.currentElapsed(at: context.date) / np.duration))
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
