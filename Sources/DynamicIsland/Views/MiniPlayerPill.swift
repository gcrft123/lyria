import SwiftUI

/// The shrunken Now Playing player shown on the Search/Library tabs: a floating
/// liquid-glass pill with artwork + title/artist (tap to open Now Playing), a
/// transport + favorite + more cluster, and a thin seek bar inset along the bottom.
struct MiniPlayerPill: View {
    @ObservedObject var controller: DynamicIslandController
    let onTap: () -> Void

    private var accent: Color {
        controller.nowPlaying.map { controller.settings.accent(for: $0) } ?? Palette.neutralAccent
    }

    var body: some View {
        if let np = controller.nowPlaying {
            VStack(spacing: Spacing.sm) {
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
                seekBar(np)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(GlassPill(cornerRadius: Radius.xl))
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
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

    /// A thin seek bar inset by the corner radius so it stays clear of the pill's
    /// rounded ends, advanced live between polls via `currentElapsed`.
    private func seekBar(_ np: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let frac = np.duration > 0
                ? min(1, max(0, np.currentElapsed(at: context.date) / np.duration))
                : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceStrong)
                    Capsule().fill(accent).frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, Spacing.md)
    }
}
