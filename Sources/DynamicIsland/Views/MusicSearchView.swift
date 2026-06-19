import SwiftUI

/// Data for a "see all" full-list page — a collections grid OR a song list.
struct MusicSeeAllData: Identifiable {
    let id = UUID()
    let title: String
    var collections: [MusicCollection] = []
    var songs: [MusicSong] = []
}

/// The Search tab: Top Results, then Albums (carousel), Songs (list), and Playlists
/// (carousel), driven by the store's debounced search.
struct MusicSearchView: View {
    @ObservedObject var store: MusicLibraryStore
    let accent: Color
    let openCollection: (MusicCollection) -> Void
    let goToAlbum: (MusicSong) -> Void
    let seeAll: (MusicSeeAllData) -> Void

    private let coverWidth: CGFloat = 96
    private let songPreview = 4

    var body: some View {
        if store.query.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt("Search songs, albums, and playlists")
        } else if store.results.isEmpty {
            prompt("No results for “\(store.query)”")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    let r = store.results
                    if !r.songs.isEmpty {
                        section("Songs", seeAllData: r.songs.count > songPreview
                                ? MusicSeeAllData(title: "Songs", songs: r.songs) : nil) {
                            VStack(spacing: Spacing.xxs) { ForEach(r.songs.prefix(songPreview)) { songRow($0) } }
                        }
                    }
                    if !r.albums.isEmpty { carousel("Albums", r.albums) }
                    if !r.playlists.isEmpty { carousel("Playlists", r.playlists) }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Layout.musicMiniClearance)
            }
            .smoothScrollBounce()
        }
    }

    private func songRow(_ s: MusicSong) -> some View {
        SongRow(store: store, song: s, accent: accent) { goToAlbum(s) }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, seeAllData: MusicSeeAllData? = nil,
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            MusicSectionHeader(title: title, accent: accent,
                               onSeeAll: seeAllData.map { d in { seeAll(d) } })
            content()
        }
    }

    private func carousel(_ title: String, _ items: [MusicCollection]) -> some View {
        section(title, seeAllData: items.count > 3 ? MusicSeeAllData(title: title, collections: items) : nil) {
            MusicCarousel(store: store, items: items, accent: accent, coverWidth: coverWidth, openCollection: openCollection)
        }
    }

    private func prompt(_ text: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "magnifyingglass").font(.system(size: IconSize.xxxl, weight: .semibold)).foregroundStyle(Palette.textFaint)
            Text(text).font(Typography.footnote).foregroundStyle(Palette.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.xxl)
    }
}

/// A full-list page for a section's "see all": a grid of covers, or a song list.
struct MusicSeeAllView: View {
    @ObservedObject var store: MusicLibraryStore
    let data: MusicSeeAllData
    let accent: Color
    let onBack: () -> Void
    let openCollection: (MusicCollection) -> Void
    let goToAlbum: (MusicSong) -> Void

    var body: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Text(data.title).font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
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
            }

            ScrollView(.vertical, showsIndicators: false) {
                if !data.collections.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Spacing.lg)],
                              alignment: .leading, spacing: Spacing.lg) {
                        ForEach(data.collections) { c in
                            CollectionCoverCell(store: store, collection: c, width: 104, accent: accent) { openCollection(c) }
                        }
                    }
                    .padding(.bottom, Layout.musicMiniClearance)
                } else {
                    VStack(spacing: Spacing.xxs) {
                        ForEach(data.songs) { s in
                            SongRow(store: store, song: s, accent: accent) { goToAlbum(s) }
                        }
                    }
                    .padding(.bottom, Layout.musicMiniClearance)
                }
            }
            .smoothScrollBounce()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
