import SwiftUI

/// The "Up Next" queue list shown down the right side of the expanded Music app.
/// A header + a scrolling list of upcoming tracks (title · artist) on the island's
/// black background, with an empty state when there's no playlist context.
struct QueueSidebar: View {
    let queue: [QueueTrack]

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
                            row(item)
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

    private func row(_ item: QueueTrack) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            Text(item.title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            if !item.artist.isEmpty {
                Text(item.artist)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
