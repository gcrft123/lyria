import SwiftUI

/// A square cover cell for a playlist/album carousel or grid: the cover with a play
/// button on its bottom-right, the title/artist beneath, and a more button right of
/// them. Tapping anywhere but the play button opens the collection's detail page.
struct CollectionCoverCell: View {
    @ObservedObject var store: MusicLibraryStore
    let collection: MusicCollection
    var width: CGFloat = 96
    let accent: Color
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(image: collection.artwork, size: width, cornerRadius: Radius.md)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen() }
                coverPlayButton { store.play(collection) }
                    .padding(Spacing.xs)
            }
            HStack(alignment: .top, spacing: Spacing.xs) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(collection.title).font(Typography.caption).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    Text(collection.subtitle).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }
                CollectionMenu(store: store, collection: collection)
            }
        }
        .frame(width: width)
    }
}

/// A play disc overlaid on a cover's corner.
func coverPlayButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "play.fill")
            .font(.system(size: IconSize.sm, weight: .bold))
            .foregroundStyle(Palette.onAccent)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Palette.textPrimary))
            .raisedShadow()
            .contentShape(Circle())
    }
    .buttonStyle(.islandSubtle)
}

/// A song list row: artwork, stacked title/artist, then the more · favorite · play
/// cluster on the right (play furthest right). Tapping the row plays the song.
struct SongRow: View {
    @ObservedObject var store: MusicLibraryStore
    let song: MusicSong
    let accent: Color
    /// Navigate to this song's album detail ("Go to Album").
    var onGoToAlbum: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            ArtworkView(image: song.artwork, size: 40, cornerRadius: Radius.sm)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(song.title).font(Typography.calloutStrong).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(song.artist).font(Typography.footnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            SongMenu(store: store, song: song, onGoToAlbum: onGoToAlbum)
            FavoriteButton(isFavorited: store.isFavorited(song), size: IconSize.md) { store.toggleFavorite(song) }
            rowIconButton("play.fill", tint: Palette.textPrimary) { store.playSong(song) }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(hovering ? Palette.surface : .clear))
        .contentShape(Rectangle())
        .onTapGesture { store.playSong(song) }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

private func rowIconButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: IconSize.md, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }
    .buttonStyle(.islandSubtle)
}

// MARK: - More menus

/// The ••• menu for a song: Add to (Favorite / Playlist ▸), Play, Shuffle, Go to
/// Album, Open in Apple Music.
struct SongMenu: View {
    @ObservedObject var store: MusicLibraryStore
    let song: MusicSong
    var onGoToAlbum: () -> Void = {}

    var body: some View {
        Menu {
            Menu("Add to") {
                Button { store.toggleFavorite(song) } label: {
                    Label(store.isFavorited(song) ? "Favorited" : "Favorite", systemImage: "heart")
                }
                Menu("Playlist") {
                    if store.playlists.isEmpty {
                        Text("No playlists")
                    } else {
                        ForEach(store.playlists) { p in
                            Button(p.title) { store.addToPlaylist(song, to: p) }
                        }
                    }
                }
            }
            Divider()
            Button { store.playSong(song) } label: { Label("Play", systemImage: "play.fill") }
            Button { store.playSong(song) } label: { Label("Shuffle", systemImage: "shuffle") }
            Button { onGoToAlbum() } label: { Label("Go to Album", systemImage: "square.stack") }
            Divider()
            Button { store.openInAppleMusic(song) } label: { Label("Open in Apple Music", systemImage: "arrow.up.forward.app") }
        } label: { ellipsisLabel }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
    }
}

/// The ••• menu for a playlist/album: Play, Shuffle, Open in Apple Music.
struct CollectionMenu: View {
    @ObservedObject var store: MusicLibraryStore
    let collection: MusicCollection

    var body: some View {
        Menu {
            Button { store.play(collection) } label: { Label("Play", systemImage: "play.fill") }
            Button { store.play(collection, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            Divider()
            Button { store.openInAppleMusic(collection) } label: { Label("Open in Apple Music", systemImage: "arrow.up.forward.app") }
        } label: { ellipsisLabel }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
    }
}

private var ellipsisLabel: some View {
    Image(systemName: "ellipsis")
        .font(.system(size: IconSize.md, weight: .semibold))
        .foregroundStyle(Palette.textSecondary)
        .frame(width: 28, height: 28)
        .contentShape(Circle())
}

/// A horizontal row of cover cells, shared by Search and Library. A plain
/// `ScrollView(.horizontal)` (not `HWheelScroll`), so the mouse wheel scrolls the
/// page vertically instead of dragging the carousel.
struct MusicCarousel: View {
    @ObservedObject var store: MusicLibraryStore
    let items: [MusicCollection]
    let accent: Color
    var coverWidth: CGFloat = 96
    let openCollection: (MusicCollection) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                ForEach(items) { c in
                    CollectionCoverCell(store: store, collection: c, width: coverWidth, accent: accent) { openCollection(c) }
                }
            }
            .padding(.horizontal, Spacing.hairline)
        }
        .smoothScrollBounce()
    }
}

/// An accent-coloured section header. With a "see all" handler the WHOLE row is the
/// tap target (not just the chevron), and the chevron nudges on hover.
struct MusicSectionHeader: View {
    let title: String
    let accent: Color
    var onSeeAll: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        if let onSeeAll {
            Button(action: onSeeAll) { row }
                .buttonStyle(.islandFlat)
                .onHover { hovering = $0 }
                .animation(Motion.hover, value: hovering)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: Spacing.sm) {
            Text(title).font(Typography.subheadline).foregroundStyle(accent)
            Spacer(minLength: 0)
            if onSeeAll != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.md, weight: .bold))
                    .foregroundStyle(accent)
                    .offset(x: hovering ? Spacing.xxs : 0)
            }
        }
        .contentShape(Rectangle())
    }
}
