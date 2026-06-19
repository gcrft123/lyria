import SwiftUI

/// The "Up Next" queue list shown down the right side of the expanded Music app.
/// A header + a scrolling list of upcoming tracks (title · artist) on the island's
/// black background, with an empty state when there's no playlist context.
struct QueueSidebar: View {
    let queue: [QueueTrack]
    /// Play the tapped upcoming track.
    var onPlay: (QueueTrack) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.md)

            if queue.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: IconSize.xl))
                        .foregroundStyle(Palette.textFaint)
                    Text("No upcoming tracks")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Spacing.xl)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: Spacing.hairline) {
                        ForEach(queue) { item in
                            QueueRow(item: item, onPlay: onPlay)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.xl)
                }
                .smoothScrollBounce()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One tappable Up Next row — tap to jump to that track; a play glyph appears on hover.
private struct QueueRow: View {
    let item: QueueTrack
    let onPlay: (QueueTrack) -> Void
    @State private var hovering = false

    var body: some View {
        Button { onPlay(item) } label: {
            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(item.title).font(Typography.caption).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    if !item.artist.isEmpty {
                        Text(item.artist).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if hovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: IconSize.sm, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(hovering ? Palette.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.islandFlat)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}
