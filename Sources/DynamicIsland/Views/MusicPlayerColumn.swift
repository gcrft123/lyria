import SwiftUI

/// The Music player's column of rows — the SINGLE source of truth, used both by
/// the full Music app (`MusicView`'s Now Playing tab, with the volume speaker +
/// reveal) and by the Dashboard's "music mirror" (`showsVolume: false`).
///
/// Keeping it in ONE place is the standard: the full player and the dashboard
/// mirror must never drift in spacing, color, glyph size, or row layout. Row
/// heights/margins come from `IslandConfiguration` so the column fills the
/// standard card height exactly.
struct MusicPlayerColumn: View {
    @ObservedObject var controller: DynamicIslandController
    /// The full player shows the volume speaker icon + slide-down volume row;
    /// the dashboard mirror has no volume control.
    var showsVolume: Bool = true
    /// Vertical gap between rows. Defaults to the standard `expandedRowSpacing`
    /// (Dashboard mirror + full-height use); the tabbed Now Playing passes a tighter
    /// value so the player fits beneath the tab bar within the 324 card.
    var rowSpacing: CGFloat? = nil
    /// Top/bottom inset. Defaults to `expandedVMargin`; tighter under the tab bar.
    var vMargin: CGFloat? = nil

    @State private var seekHovered = false
    @State private var volumeRowHovered = false

    private var config: IslandConfiguration { controller.configuration }
    private var settings: AppSettings { controller.settings }
    private var volumeShown: Bool { showsVolume && controller.volumeBarVisible }

    private func tint(_ np: NowPlaying) -> Color { settings.accent(for: np) }

    var body: some View {
        if let np = controller.nowPlaying {
            VStack(spacing: rowSpacing ?? config.expandedRowSpacing) {
                topRow(np)
                progressRow(np)
                transportRow(np)
                if volumeShown {
                    volumeRow(np)
                        .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
                }
                bottomRow(np)
            }
            .padding(.horizontal, config.expandedHMargin)
            .padding(.vertical, vMargin ?? config.expandedVMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .buttonStyle(.island)
            // Animate the volume reveal in step with the card's height morph.
            .animation(Motion.morph, value: volumeShown)
        } else {
            placeholder
        }
    }

    /// Shown when Music is selected but nothing is playing.
    private var placeholder: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "music.note")
                .font(.system(size: IconSize.xxxl, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            Text("Nothing Playing")
                .font(Typography.subheadline)
                .foregroundStyle(Palette.textSecondary)
            Text("Start a song in Apple Music")
                .font(Typography.footnote)
                .foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Rows

    private func topRow(_ np: NowPlaying) -> some View {
        HStack(spacing: Spacing.xl) {
            ArtworkView(image: np.artwork, size: config.topRowHeight, cornerRadius: Radius.md)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(np.title)
                    .font(Typography.subheadline).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    .contentShape(Rectangle()).onTapGesture { controller.openSongPage() }
                Text(np.artist)
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    .contentShape(Rectangle()).onTapGesture { controller.openArtistPage() }
            }
            Spacer(minLength: Spacing.md)
            FavoriteButton(isFavorited: np.isFavorited, size: IconSize.lg) { controller.toggleFavorite() }
            if settings.showEqualizerBars {
                NowPlayingBars(color: tint(np), isPlaying: np.isPlaying, maxHeight: 16).frame(width: 20)
            }
        }
        .frame(height: config.topRowHeight)
    }

    private func progressRow(_ np: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let elapsed = np.currentElapsed(at: context.date)
            let remaining = max(0, np.duration - elapsed)
            VStack(spacing: Spacing.sm) {
                ProgressBarView(
                    elapsed: elapsed, duration: np.duration, accent: tint(np),
                    isHovered: seekHovered,
                    onCommit: { controller.seek(to: $0) }
                )
                .onHover { seekHovered = $0 }
                let elapsedText = formatTime(elapsed)
                HStack {
                    Text(elapsedText).contentTransition(.numericText())
                    Spacer()
                    Text("-" + formatTime(remaining)).contentTransition(.numericText())
                }
                .font(Typography.footnoteMono)
                .foregroundStyle(Palette.textTertiary)
                .animation(Motion.hover, value: elapsedText)
            }
        }
        .frame(height: config.progressRowHeight)
    }

    private func transportRow(_ np: NowPlaying) -> some View {
        ZStack {
            HStack(spacing: Spacing.xxl) {
                transportButton("backward.fill", glyphSize: IconSize.xl) { controller.previousTrack() }
                transportButton(np.isPlaying ? "pause.fill" : "play.fill", glyphSize: IconSize.xxxl) { controller.playPause() }
                transportButton("forward.fill", glyphSize: IconSize.xl) { controller.nextTrack() }
            }
            // The volume speaker icon (full player only) — TAP it to toggle the
            // slide-down volume row (the old hover-zone reveal didn't survive the
            // tab bar's vertical offset).
            if showsVolume {
                HStack {
                    Button(action: { controller.toggleVolumeReveal() }) {
                        Image(systemName: volumeSymbol(np.volume))
                            .font(.system(size: IconSize.lg))
                            .foregroundStyle(volumeShown ? tint(np) : Palette.textSecondary)
                            .frame(width: 30, height: config.transportRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.island)
                    Spacer()
                }
            }
        }
        .foregroundStyle(Palette.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: config.transportRowHeight)
    }

    private func volumeRow(_ np: NowPlaying) -> some View {
        VolumeSliderView(
            volume: np.volume,
            accent: tint(np),
            isHovered: volumeRowHovered,
            onChange: { controller.setVolume(to: $0) }
        )
        .frame(height: config.volumeRowHeight)
        .onHover { volumeRowHovered = $0 }
    }

    private func bottomRow(_ np: NowPlaying) -> some View {
        HStack(spacing: Spacing.zero) {
            Button(action: { controller.toggleShuffle() }) {
                Image(systemName: "shuffle")
                    .foregroundStyle(np.shuffle ? tint(np) : Palette.textSecondary)
                    .frame(width: 48, height: config.bottomRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            Spacer()
            AirPlayButton(activeTint: NSColor(tint(np)))
                .frame(width: 26, height: 26)
            Spacer()
            Button(action: { controller.cycleRepeat() }) {
                Image(systemName: np.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(np.repeatMode == .off ? Palette.textSecondary : tint(np))
                    .frame(width: 48, height: config.bottomRowHeight, alignment: .trailing)
                    .contentShape(Rectangle())
            }
        }
        .font(.system(size: IconSize.md, weight: .semibold))
        .frame(height: config.bottomRowHeight)
    }

    private func transportButton(_ symbol: String, glyphSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize))
                .frame(width: 52, height: config.transportRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.islandSubtle)
    }

    private func volumeSymbol(_ volume: Double) -> String {
        switch volume {
        case ..<0.001: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
