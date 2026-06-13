import SwiftUI

/// The full Music app: the shared `MusicPlayerColumn` on the left (the standard
/// 508pt content width), a 1px divider, and the "Up Next" queue sidebar on the
/// right. The player itself lives in `MusicPlayerColumn` so it stays identical to
/// the Dashboard's mirror; this view only composes it with the queue.
struct ExpandedPlayerView: View {
    @ObservedObject var controller: DynamicIslandController

    private var config: IslandConfiguration { controller.configuration }

    var body: some View {
        if let nowPlaying = controller.nowPlaying {
            HStack(spacing: Spacing.zero) {
                MusicPlayerColumn(controller: controller)
                    .frame(width: config.musicPlayerWidth)
                Rectangle()
                    .fill(Palette.hairlineStroke)
                    .frame(width: 1)
                    .padding(.vertical, Spacing.lg)
                QueueSidebar(queue: nowPlaying.queue)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .buttonStyle(.island)
        } else {
            // The column renders the shared "Nothing Playing" placeholder.
            MusicPlayerColumn(controller: controller)
        }
    }
}
