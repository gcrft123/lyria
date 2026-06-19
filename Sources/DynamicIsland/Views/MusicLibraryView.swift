import SwiftUI

/// The Library tab: the user's saved Playlists, then Albums, then Songs. The tab
/// bar's "Find in library…" field filters the loaded lists client-side (no network
/// search — that's the Search tab).
struct MusicLibraryView: View {
    @ObservedObject var store: MusicLibraryStore
    let accent: Color
    /// The live "Find in library…" text.
    let filter: String
    let openCollection: (MusicCollection) -> Void
    let goToAlbum: (MusicSong) -> Void
    let seeAll: (MusicSeeAllData) -> Void

    private let coverWidth: CGFloat = 96
    private let songPreview = 4

    private var query: String { filter.trimmingCharacters(in: .whitespaces).lowercased() }
    private var playlists: [MusicCollection] { filtered(store.playlists) }
    private var albums: [MusicCollection] { filtered(store.albums) }
    private var songs: [MusicSong] {
        let all = store.albums.flatMap(\.songs)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(query)
                || $0.artist.lowercased().contains(query)
                || $0.album.lowercased().contains(query)
        }
    }

    var body: some View {
        if store.playlists.isEmpty && store.albums.isEmpty {
            prompt("square.stack", "Your playlists and albums will appear here")
        } else if playlists.isEmpty && albums.isEmpty && songs.isEmpty {
            prompt("magnifyingglass", "Nothing in your library matches “\(filter)”")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if !playlists.isEmpty {
                        section("Playlists", all: playlists.count > 3 ? MusicSeeAllData(title: "Playlists", collections: playlists) : nil) {
                            MusicCarousel(store: store, items: playlists, accent: accent, coverWidth: coverWidth, openCollection: openCollection)
                        }
                    }
                    if !albums.isEmpty {
                        section("Albums", all: albums.count > 3 ? MusicSeeAllData(title: "Albums", collections: albums) : nil) {
                            MusicCarousel(store: store, items: albums, accent: accent, coverWidth: coverWidth, openCollection: openCollection)
                        }
                    }
                    if !songs.isEmpty {
                        section("Songs", all: songs.count > songPreview ? MusicSeeAllData(title: "Songs", songs: songs) : nil) {
                            VStack(spacing: Spacing.xxs) {
                                ForEach(songs.prefix(songPreview)) { s in
                                    SongRow(store: store, song: s, accent: accent) { goToAlbum(s) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Layout.musicMiniClearance)
            }
            .smoothScrollBounce()
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, all: MusicSeeAllData? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            MusicSectionHeader(title: title, accent: accent, onSeeAll: all.map { d in { seeAll(d) } })
            content()
        }
    }

    private func filtered(_ items: [MusicCollection]) -> [MusicCollection] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(query) || $0.subtitle.lowercased().contains(query) }
    }

    private func prompt(_ icon: String, _ text: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon).font(.system(size: IconSize.xxxl, weight: .semibold)).foregroundStyle(Palette.textFaint)
            Text(text).font(Typography.footnote).foregroundStyle(Palette.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.xxl)
    }
}
