import Foundation

/// The view-facing state for the Music app's Search + Library tabs: holds the
/// library lists and the latest (debounced) search results, and forwards actions to
/// the underlying `MusicLibrary`. Owned by `DynamicIslandController`.
@MainActor
final class MusicLibraryStore: ObservableObject {
    @Published private(set) var playlists: [MusicCollection] = []
    @Published private(set) var albums: [MusicCollection] = []
    /// The full library song pool (Library tab's Songs section + "Find in library…").
    @Published private(set) var librarySongs: [MusicSong] = []
    @Published private(set) var results: SearchResults = .empty
    @Published private(set) var query: String = ""
    @Published private(set) var isSearching = false
    /// Optimistic favorite state by song id, so a tapped heart fills immediately
    /// (the real favorite is applied in Music asynchronously).
    @Published private(set) var favoriteOverrides: [String: Bool] = [:]

    // Music app navigation, owned here (not in `MusicView`'s `@State`) so it survives
    // the view being torn down on app switch / island collapse — returning to Music
    // lands on the same screen instead of resetting to Now Playing.
    @Published var tab: MusicTab = MusicTab.fromEnv(ProcessInfo.processInfo.environment["DI_MUSIC_TAB"]) ?? .nowPlaying
    /// The tab bar's search / "Find in library…" field text.
    @Published var fieldText: String = ""
    /// Pushed sub-pages within the browse tabs (collection detail, "see all" list).
    @Published var detail: MusicCollection?
    @Published var seeAll: MusicSeeAllData?

    private let library: MusicLibrary
    private var searchTask: Task<Void, Never>?
    private var loaded = false

    init(library: MusicLibrary) { self.library = library }

    /// Load the Library lists once (kept around while the app stays running).
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        Task {
            playlists = await library.playlists()
            albums = await library.albums()
            librarySongs = await library.librarySongs()
        }
    }

    /// Update the live query and (debounced) re-run the search. An empty query
    /// clears results immediately.
    func search(_ text: String) {
        query = text
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = .empty; isSearching = false; return }
        isSearching = true
        searchTask = Task { [library] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // debounce keystrokes
            if Task.isCancelled { return }
            // `search` already reflects real library favorite state on its hits, so the
            // rows render with the right heart on first paint (no late flip, which would
            // make every favorited row fire its celebratory heart-burst on load).
            let r = await library.search(q)
            if Task.isCancelled { return }
            self.results = r
            self.isSearching = false
        }
    }

    /// Reset the search field/results (e.g. when leaving the Search tab).
    func clearSearch() {
        searchTask?.cancel()
        query = ""
        results = .empty
        isSearching = false
    }

    /// Fetch a collection's tracks on demand (for the detail page).
    func songs(in collection: MusicCollection) async -> [MusicSong] {
        await library.songs(in: collection)
    }

    // MARK: Actions
    func play(_ c: MusicCollection, shuffled: Bool = false) { library.play(c, shuffled: shuffled) }
    func playSong(_ s: MusicSong) { library.playSong(s) }

    /// Whether a song reads as favorited (optimistic override, else its loaded state).
    func isFavorited(_ s: MusicSong) -> Bool { favoriteOverrides[s.id] ?? s.isFavorited }

    func toggleFavorite(_ s: MusicSong) {
        favoriteOverrides[s.id] = !isFavorited(s)
        library.toggleFavorite(s)
    }
    func addToPlaylist(_ s: MusicSong, to p: MusicCollection) { library.addToPlaylist(s, to: p) }
    func openInAppleMusic(_ s: MusicSong) { library.openInAppleMusic(song: s) }
    func openInAppleMusic(_ c: MusicCollection) { library.openInAppleMusic(collection: c) }
}
