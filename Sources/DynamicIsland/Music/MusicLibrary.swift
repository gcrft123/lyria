import AppKit

/// A song — a library track, a search hit, or a row in a collection's track list.
struct MusicSong: Identifiable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var albumID: String?
    var artwork: NSImage?
    var duration: TimeInterval
    var isFavorited: Bool = false
}

/// A playlist or an album: a square-cover collection of songs.
struct MusicCollection: Identifiable {
    enum Kind { case playlist, album }
    let id: String
    var kind: Kind
    var title: String
    /// Album → artist; playlist → curator/owner.
    var subtitle: String
    var artwork: NSImage?
    /// Release date (album) or created date (playlist).
    var date: Date?
    var songs: [MusicSong]

    var totalDuration: TimeInterval { songs.reduce(0) { $0 + $1.duration } }
}

/// The results of a search query, grouped for display (Top Results first).
struct SearchResults {
    var topResults: [MusicSong] = []
    var albums: [MusicCollection] = []
    var songs: [MusicSong] = []
    var playlists: [MusicCollection] = []

    var isEmpty: Bool {
        topResults.isEmpty && albums.isEmpty && songs.isEmpty && playlists.isEmpty
    }
    static let empty = SearchResults()
}

/// The data + actions backing the Music app's Search and Library tabs. Swapping the
/// implementation (mock ↔ real Apple Music) leaves the UI untouched — that's the
/// whole point of the seam (see `MockMusicLibrary`, and later `AppleMusicLibrary`).
/// Fetches are `async` so a real, off-main ScriptingBridge backend can do slow work
/// without blocking; actions are fire-and-forget.
protocol MusicLibrary: AnyObject {
    func playlists() async -> [MusicCollection]
    func albums() async -> [MusicCollection]
    func search(_ query: String) async -> SearchResults
    /// A collection's track list, fetched on demand (real playlists/albums don't
    /// load every track upfront). Mock returns the already-attached `songs`.
    func songs(in collection: MusicCollection) async -> [MusicSong]

    func play(_ collection: MusicCollection, shuffled: Bool)
    func playSong(_ song: MusicSong)
    func toggleFavorite(_ song: MusicSong)
    func addToPlaylist(_ song: MusicSong, to playlist: MusicCollection)
    func openInAppleMusic(song: MusicSong)
    func openInAppleMusic(collection: MusicCollection)
}
