import SwiftUI

/// A playlist/album detail page: a hero (cover, title, artist, song count + length,
/// Play + Shuffle) over the scrollable song list. Reached by tapping a cover, a
/// "see all" item, or a song's "Go to Album". Shared by Search and Library.
struct MusicCollectionDetailView: View {
    @ObservedObject var store: MusicLibraryStore
    let collection: MusicCollection
    let accent: Color
    let onBack: () -> Void
    var onGoToAlbum: (MusicSong) -> Void = { _ in }

    @State private var songs: [MusicSong] = []

    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.left").font(.system(size: IconSize.sm, weight: .bold))
                        Text("Back").font(Typography.callout)
                    }
                    .foregroundStyle(accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.islandFlat)
                Spacer()
            }

            // The hero and the song list are ONE scrolling page (the header scrolls
            // away with the songs, rather than sitting in a separate scroll box).
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    hero
                    if songs.isEmpty {
                        Text("Loading…")
                            .font(Typography.footnote).foregroundStyle(Palette.textTertiary)
                            .frame(maxWidth: .infinity).padding(.top, Spacing.xxl)
                    } else {
                        VStack(spacing: Spacing.xxs) {
                            ForEach(songs) { song in
                                SongRow(store: store, song: song, accent: accent) { onGoToAlbum(song) }
                            }
                        }
                    }
                }
                .padding(.bottom, Layout.musicMiniClearance)
            }
            .smoothScrollBounce()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: collection.id) { songs = await store.songs(in: collection) }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            ArtworkView(image: collection.artwork, size: 92, cornerRadius: Radius.lg)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(collection.title).font(Typography.title2).foregroundStyle(Palette.textPrimary).lineLimit(2)
                Text(collection.subtitle).font(Typography.callout).foregroundStyle(accent).lineLimit(1)
                Text(metaLine).font(Typography.footnote).foregroundStyle(Palette.textTertiary).lineLimit(1)
                HStack(spacing: Spacing.sm) {
                    actionPill("Play", "play.fill", filled: true) { store.play(collection) }
                    actionPill("Shuffle", "shuffle", filled: false) { store.play(collection, shuffled: true) }
                }
                .padding(.top, Spacing.xs)
            }
            Spacer(minLength: 0)
        }
    }

    private var metaLine: String {
        guard !songs.isEmpty else { return "Loading…" }
        let count = songs.count
        let minutes = max(1, Int((songs.reduce(0) { $0 + $1.duration } / 60).rounded()))
        var parts = ["\(count) \(count == 1 ? "song" : "songs")", "\(minutes) min"]
        if let date = collection.date {
            let f = DateFormatter(); f.dateFormat = "yyyy"
            parts.append(f.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    private func actionPill(_ title: String, _ icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon).font(.system(size: IconSize.sm, weight: .bold))
                Text(title).font(Typography.calloutStrong)
            }
            .foregroundStyle(filled ? Palette.onAccent : accent)
            .padding(.horizontal, Spacing.lg)
            .frame(height: 30)
            .background(Capsule().fill(filled ? accent : Palette.surfaceRaised))
            .contentShape(Capsule())
        }
        .buttonStyle(.island)
    }
}
