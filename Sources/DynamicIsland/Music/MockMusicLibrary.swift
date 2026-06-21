import AppKit

/// A rich static catalog backing Search + Library when `DI_MOCK_MUSIC=1` (and the
/// dev/screenshot default until the real `AppleMusicLibrary` lands). Generates simple
/// gradient cover art so carousels read as distinct items.
final class MockMusicLibrary: MusicLibrary {

    private let catalogAlbums: [MusicCollection]
    private let catalogPlaylists: [MusicCollection]
    /// Every song across all albums (the searchable pool).
    private let allSongs: [MusicSong]

    init() {
        let albums = MockMusicLibrary.makeAlbums()
        catalogAlbums = albums
        allSongs = albums.flatMap(\.songs)
        catalogPlaylists = MockMusicLibrary.makePlaylists(from: albums)
    }

    func playlists() async -> [MusicCollection] { catalogPlaylists }
    func albums() async -> [MusicCollection] { catalogAlbums }
    func librarySongs() async -> [MusicSong] { allSongs }
    func songs(in collection: MusicCollection) async -> [MusicSong] { collection.songs }

    func search(_ query: String) async -> SearchResults {
        let q = query.lowercased()
        guard !q.isEmpty else { return .empty }

        let scored = allSongs
            .map { (song: $0, score: MockMusicLibrary.score($0, query: q)) }
            .filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.song.title < $1.song.title }
        let songs = scored.map(\.song)

        let albums = catalogAlbums.filter { album in
            album.title.lowercased().contains(q)
                || album.subtitle.lowercased().contains(q)
                || album.songs.contains { Self.score($0, query: q) > 0 }
        }
        let playlists = catalogPlaylists.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
        return SearchResults(topResults: Array(songs.prefix(3)),
                             albums: albums, songs: songs, playlists: playlists)
    }

    // Actions — the mock can really open Apple Music; playback/favorite are no-ops
    // (there's no live mock player to drive). The real backend will wire these up.
    func play(_ collection: MusicCollection, shuffled: Bool) {}
    func playSong(_ song: MusicSong) {}
    func toggleFavorite(_ song: MusicSong) {}
    func addToPlaylist(_ song: MusicSong, to playlist: MusicCollection) {}
    func openInAppleMusic(song: MusicSong) { AppleMusicLinks.openSong(title: song.title, artist: song.artist) }
    func openInAppleMusic(collection: MusicCollection) {
        AppleMusicLinks.openSong(title: collection.title, artist: collection.subtitle)
    }

    private static func score(_ song: MusicSong, query q: String) -> Int {
        let title = song.title.lowercased()
        if title.hasPrefix(q) { return 3 }
        if title.contains(q) { return 2 }
        if song.artist.lowercased().contains(q) || song.album.lowercased().contains(q) { return 1 }
        return 0
    }

    // MARK: Static catalog

    private static func makeAlbums() -> [MusicCollection] {
        let raw: [(String, String, [NSColor], [(String, Int)])] = [
            ("Rumours", "Fleetwood Mac", [.systemPurple, .systemPink],
             [("Dreams", 257), ("Go Your Own Way", 218), ("The Chain", 268), ("Songbird", 200), ("Don't Stop", 191)]),
            ("Random Access Memories", "Daft Punk", [.systemBlue, .systemIndigo],
             [("Get Lucky", 369), ("Instant Crush", 337), ("Lose Yourself to Dance", 353), ("Giorgio by Moroder", 544)]),
            ("Blonde", "Frank Ocean", [.systemOrange, .systemYellow],
             [("Nikes", 314), ("Ivy", 249), ("Pink + White", 184), ("Self Control", 249), ("Nights", 307)]),
            ("In Rainbows", "Radiohead", [.systemRed, .systemOrange],
             [("15 Step", 237), ("Bodysnatchers", 242), ("Nude", 255), ("Weird Fishes", 318), ("Reckoner", 290)]),
            ("Currents", "Tame Impala", [.systemTeal, .systemGreen],
             [("Let It Happen", 467), ("The Less I Know the Better", 216), ("Eventually", 320), ("New Person, Same Old Mistakes", 360)]),
            ("Discovery", "Daft Punk", [.systemPink, .systemPurple],
             [("One More Time", 320), ("Aerodynamic", 213), ("Digital Love", 301), ("Harder, Better, Faster, Stronger", 224)]),
        ]
        return raw.enumerated().map { index, a in
            let (title, artist, colors, tracks) = a
            let art = swatch(colors)
            let id = "album.\(index)"
            let songs = tracks.enumerated().map { ti, t in
                // Seed a couple of favorites so the filled-heart state is visible in
                // mock screenshots/tests.
                MusicSong(id: "\(id).song.\(ti)", title: t.0, artist: artist,
                          album: title, albumID: id, artwork: art, duration: TimeInterval(t.1),
                          isFavorited: ti == 0 && index % 2 == 0)
            }
            return MusicCollection(id: id, kind: .album, title: title, subtitle: artist,
                                   artwork: art, date: nil, songs: songs)
        }
    }

    private static func makePlaylists(from albums: [MusicCollection]) -> [MusicCollection] {
        let pool = albums.flatMap(\.songs)
        func pick(_ indices: [Int]) -> [MusicSong] { indices.compactMap { pool.indices.contains($0) ? pool[$0] : nil } }
        let specs: [(String, String, [NSColor], [Int])] = [
            ("Focus Flow", "Lyria", [.systemIndigo, .systemBlue], [1, 6, 10, 14, 20]),
            ("Late Night", "Lyria", [.systemPurple, .systemBlue], [0, 8, 12, 16, 22]),
            ("Throwback Hits", "Apple Music", [.systemOrange, .systemRed], [2, 24, 25, 9]),
            ("Chill Vibes", "Apple Music", [.systemTeal, .systemGreen], [3, 11, 17, 19]),
            ("Dance Party", "Lyria", [.systemPink, .systemPurple], [1, 23, 26, 27]),
        ]
        return specs.enumerated().map { index, s in
            MusicCollection(id: "playlist.\(index)", kind: .playlist, title: s.0, subtitle: s.1,
                            artwork: swatch(s.2), date: nil, songs: pick(s.3))
        }
    }

    /// A diagonal two-tone gradient cover so each item reads distinctly.
    private static func swatch(_ colors: [NSColor]) -> NSImage {
        let size = NSSize(width: 160, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        let top = colors.first ?? .systemGray
        let bottom = colors.count > 1 ? colors[1] : (top.blended(withFraction: 0.35, of: .black) ?? top)
        if let gradient = NSGradient(starting: top, ending: bottom) {
            gradient.draw(in: NSRect(origin: .zero, size: size), angle: -60)
        } else {
            top.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        image.unlockFocus()
        return image
    }
}
