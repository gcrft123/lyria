import AppKit
import ScriptingBridge

/// The real Apple Music backend (used unless `DI_MOCK_MUSIC=1`).
///
/// - **Library** = the user's playlists + albums via ScriptingBridge, read with KVC
///   the same way `MusicBridge` reads the now-playing queue (SB element protocol
///   casts are unreliable). Albums are derived from the library playlist using the
///   bulk-KVC fast path (one Apple Event per column), grouped by album name.
/// - **Search** = Apple's public iTunes catalog API (fast, rich metadata, real
///   artwork) rather than the fragile library-wide ScriptingBridge `search` command.
/// - **Play / favorite** drive the Music app via small AppleScripts (the user's own
///   library content plays in-app; catalog-only search hits open in Apple Music).
///
/// NOT verified on a live library by the author — every read goes through the same
/// off-main serial queue + KVC discipline as `MusicBridge`, so failures degrade to
/// empty rather than crashing. Bulk album derivation can be slow on very large
/// libraries (it's done once, off-main, and cached).
final class AppleMusicLibrary: MusicLibrary, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.gcrft123.lyria.music.library")
    private var cachedApp: SBApplication?
    private var cachedPlaylists: [MusicCollection]?
    private var cachedAlbums: [MusicCollection]?
    private var cachedLibrarySongs: [MusicSong]?
    /// Lookups (built with `cachedLibrarySongs`) for resolving a catalog search hit to
    /// a saved library track: normalised title → matches, normalised album → artists.
    private var songIndex: [String: [LibRef]] = [:]
    private var albumIndex: [String: [String]] = [:]

    /// A saved library track's identity for matching a catalog hit against it.
    private struct LibRef { let artist: String; let favorited: Bool; let persistentID: String }

    /// System/special playlists that leak into `userPlaylists` and aren't real
    /// user playlists (the reported stray "Music" entry, etc.).
    private let excludedPlaylists: Set<String> = ["Music", "Library", "Downloaded", "Recently Added", "Purchased"]

    private var app: SBApplication? {
        if let cachedApp { return cachedApp }
        cachedApp = SBApplication(bundleIdentifier: "com.apple.Music")
        return cachedApp
    }

    // MARK: Library (ScriptingBridge, KVC)

    func playlists() async -> [MusicCollection] {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.loadPlaylists()) } }
    }

    func albums() async -> [MusicCollection] {
        await withCheckedContinuation { cont in
            queue.async { self.ensureLibraryLoaded(); cont.resume(returning: self.cachedAlbums ?? []) }
        }
    }

    func librarySongs() async -> [MusicSong] {
        await withCheckedContinuation { cont in
            queue.async { self.ensureLibraryLoaded(); cont.resume(returning: self.cachedLibrarySongs ?? []) }
        }
    }

    /// MUST run on `queue`. The user's playlists (name, id, cover) via KVC. Covers
    /// fall back to the first track's artwork (playlists often have none of their own).
    private func loadPlaylists() -> [MusicCollection] {
        if let cachedPlaylists { return cachedPlaylists }
        guard let app, app.isRunning, let lists = app.userPlaylists() else { return [] }
        var result: [MusicCollection] = []
        for i in 0..<min(lists.count, 60) {
            let obj = lists.object(at: i) as AnyObject
            let name = obj.value(forKey: "name") as? String ?? ""
            guard !name.isEmpty, !excludedPlaylists.contains(name) else { continue }
            let pid = obj.value(forKey: "persistentID") as? String ?? "\(i)"
            var art = Self.firstArtwork(of: obj)
            if art == nil, let tracks = obj.value(forKey: "tracks") as? SBElementArray {
                art = Self.artwork(in: tracks, at: 0)
            }
            result.append(MusicCollection(id: "pl:\(pid)", kind: .playlist, title: name,
                                          subtitle: "Playlist", artwork: art, date: nil, songs: []))
        }
        cachedPlaylists = result
        return result
    }

    /// Cap on the bulk library pass — bounds work + memory on very large libraries.
    private static let libraryTrackCap = 6000

    /// MUST run on `queue`. One bulk pass over the library that fills BOTH
    /// `cachedAlbums` (≤60 grouped albums with covers) and `cachedLibrarySongs` (the
    /// full song list, so search/Library find songs that aren't in a surfaced album).
    ///
    /// Each text property is bulk-read in one Apple Event (`value(forKey:)`); these
    /// columns are mutually aligned. **Artwork is read the SAME way** — via an
    /// aligned `artworks` column — NOT via `object(at:)`. ScriptingBridge's
    /// `object(at:)` ordering can differ from `value(forKey:)` ordering, so the old
    /// `object(at:)` cover lookup paired each album with the WRONG track's art (text
    /// was right, covers were scrambled). Reading artwork through `value(forKey:)`
    /// keeps it index-aligned with the album column.
    private func ensureLibraryLoaded() {
        if cachedAlbums != nil { return }
        guard let tracks = libraryTracks(), tracks.count > 0 else {
            cachedAlbums = []; cachedLibrarySongs = []; return
        }
        let names = Self.stringColumn(tracks, "name")
        let albumCol = Self.stringColumn(tracks, "album")
        let artistCol = Self.stringColumn(tracks, "artist")
        let albumArtistCol = Self.stringColumn(tracks, "albumArtist")
        let pidCol = Self.stringColumn(tracks, "persistentID")
        let durCol = Self.doubleColumn(tracks, "duration")
        let favCol = Self.boolColumn(tracks, "favorited")
        // Artwork relationships, read the SAME way as the text columns so they align.
        let artCol = (tracks.value(forKey: "artworks") as? [Any]) ?? []

        func str(_ c: [String], _ i: Int) -> String { i < c.count ? c[i] : "" }
        let count = min(names.count, Self.libraryTrackCap)

        // Pass 1 — album order + each album's first row (for its cover) + subtitle.
        var order: [String] = []
        var firstIndex: [String: Int] = [:]
        var subtitle: [String: String] = [:]
        for i in 0..<min(albumCol.count, Self.libraryTrackCap) {
            let album = albumCol[i]
            guard !album.isEmpty, firstIndex[album] == nil else { continue }
            order.append(album); firstIndex[album] = i
            let aa = str(albumArtistCol, i)
            subtitle[album] = aa.isEmpty ? str(artistCol, i) : aa
        }
        // Covers for up to 60 albums, realised (the `data` read) only for those rows.
        // The per-track entry is the `artworks` relationship — usually an
        // SBElementArray, but tolerate a plain array too.
        func cover(at i: Int) -> NSImage? {
            guard i >= 0, i < artCol.count else { return nil }
            if let arts = artCol[i] as? SBElementArray, arts.count > 0 {
                return (arts.object(at: 0) as AnyObject).value(forKey: "data") as? NSImage
            }
            if let arts = artCol[i] as? [Any], let first = arts.first {
                return (first as AnyObject).value(forKey: "data") as? NSImage
            }
            return nil
        }
        var albumCover: [String: NSImage] = [:]
        for album in order.prefix(60) {
            if let img = cover(at: firstIndex[album] ?? -1) { albumCover[album] = img }
        }

        // Pass 2 — the full song list (no per-song artwork pull; reuse album covers).
        var songs: [MusicSong] = []
        songs.reserveCapacity(count)
        for i in 0..<count {
            let title = str(names, i)
            guard !title.isEmpty else { continue }
            let album = str(albumCol, i)
            let pid = str(pidCol, i)
            songs.append(MusicSong(
                id: pid.isEmpty ? "\(i)" : pid,
                title: title, artist: str(artistCol, i),
                album: album, albumID: album.isEmpty ? nil : "lal:\(album)",
                artwork: album.isEmpty ? nil : albumCover[album],
                duration: i < durCol.count ? durCol[i] : 0,
                isFavorited: i < favCol.count ? favCol[i] : false))
        }
        cachedLibrarySongs = songs

        // Albums (≤60), each with its songs filtered from the full list.
        var byAlbum: [String: [MusicSong]] = [:]
        for s in songs where !s.album.isEmpty { byAlbum[s.album, default: []].append(s) }
        cachedAlbums = order.prefix(60).map { album in
            MusicCollection(id: "lal:\(album)", kind: .album, title: album,
                            subtitle: subtitle[album] ?? "", artwork: albumCover[album],
                            date: nil, songs: byAlbum[album] ?? [])
        }

        // Indices for resolving catalog search hits against the library.
        var sIndex: [String: [LibRef]] = [:]
        var aIndex: [String: [String]] = [:]
        for s in songs {
            let key = Self.matchKey(s.title)
            if !key.isEmpty {
                sIndex[key, default: []].append(
                    LibRef(artist: s.artist.lowercased(), favorited: s.isFavorited, persistentID: s.id))
            }
            if !s.album.isEmpty {
                let ak = Self.matchKey(s.album)
                if !ak.isEmpty { aIndex[ak, default: []].append(s.artist.lowercased()) }
            }
        }
        songIndex = sIndex
        albumIndex = aIndex
    }

    // MARK: Catalog-hit → library resolution (pure Swift, against the loaded library)

    /// Normalised key for fuzzy title/album matching: lowercased, with version/feature
    /// suffixes trimmed so a catalog title matches its (often suffixed) library copy
    /// — e.g. "Dreams (2004 Remaster)" and "Dreams - Single Version" both key to
    /// "dreams". This is the fix for favorited songs whose exact titles didn't match.
    private static func matchKey(_ s: String) -> String {
        var t = s.lowercased()
        for sep in [" - ", " (", " [", " feat", " ft."] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func artistMatches(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return true }
        return a.contains(b) || b.contains(a)
    }

    /// MUST run on `queue`. Match catalog songs to saved library tracks: song id →
    /// (persistent ID, favorited). Absent ⇒ not in the library.
    private func resolveSongs(_ songs: [MusicSong]) -> [String: (libraryID: String, favorited: Bool)] {
        ensureLibraryLoaded()
        guard !songIndex.isEmpty else { return [:] }
        var out: [String: (String, Bool)] = [:]
        for s in songs where s.id.hasPrefix("sg:") {
            guard let cands = songIndex[Self.matchKey(s.title)] else { continue }
            let a = s.artist.lowercased()
            if let m = cands.first(where: { Self.artistMatches($0.artist, a) }) {
                out[s.id] = (m.persistentID, m.favorited)
            }
        }
        return out
    }

    /// MUST run on `queue`. The ids of catalog albums that are in the library.
    private func resolveAlbums(_ albums: [MusicCollection]) -> Set<String> {
        ensureLibraryLoaded()
        guard !albumIndex.isEmpty else { return [] }
        var out: Set<String> = []
        for c in albums where c.id.hasPrefix("al:") {
            guard let artists = albumIndex[Self.matchKey(c.title)] else { continue }
            let a = c.subtitle.lowercased()
            if artists.contains(where: { Self.artistMatches($0, a) }) { out.insert(c.id) }
        }
        return out
    }

    func songs(in collection: MusicCollection) async -> [MusicSong] {
        if collection.id.hasPrefix("pl:") {
            let pid = String(collection.id.dropFirst(3))
            return await withCheckedContinuation { cont in
                queue.async { cont.resume(returning: self.loadPlaylistTracks(persistentID: pid)) }
            }
        }
        if collection.id.hasPrefix("lal:") {
            return await withCheckedContinuation { cont in
                queue.async {
                    self.ensureLibraryLoaded()
                    cont.resume(returning: self.cachedAlbums?.first { $0.id == collection.id }?.songs ?? collection.songs)
                }
            }
        }
        if collection.id.hasPrefix("al:") {
            return await Self.lookupAlbumTracks(collectionID: String(collection.id.dropFirst(3)))
        }
        return collection.songs
    }

    /// MUST run on `queue`. A user playlist's tracks (re-resolved by id), each with
    /// its own cover. Capped at 100 — reading per-track KVC artwork is the slow part,
    /// so very long playlists are truncated to keep the detail open responsive.
    private func loadPlaylistTracks(persistentID pid: String) -> [MusicSong] {
        guard let app, app.isRunning, let lists = app.userPlaylists() else { return [] }
        for i in 0..<lists.count {
            let obj = lists.object(at: i) as AnyObject
            guard (obj.value(forKey: "persistentID") as? String) == pid,
                  let tracks = obj.value(forKey: "tracks") as? SBElementArray else { continue }
            var songs: [MusicSong] = []
            for t in 0..<min(tracks.count, 100) {
                let e = tracks.object(at: t) as AnyObject
                let title = e.value(forKey: "name") as? String ?? ""
                guard !title.isEmpty else { continue }
                let album = e.value(forKey: "album") as? String ?? ""
                songs.append(MusicSong(id: (e.value(forKey: "persistentID") as? String) ?? "\(t)",
                                       title: title,
                                       artist: e.value(forKey: "artist") as? String ?? "",
                                       album: album, albumID: album.isEmpty ? nil : "lal:\(album)",
                                       artwork: Self.firstArtwork(of: e),
                                       duration: e.value(forKey: "duration") as? Double ?? 0,
                                       isFavorited: (e.value(forKey: "favorited") as? NSNumber)?.boolValue ?? false))
            }
            return songs
        }
        return []
    }

    /// The library playlist (the source of all tracks) via `sources`.
    private func libraryTracks() -> SBElementArray? {
        guard let app, app.isRunning, let sources = app.value(forKey: "sources") as? SBElementArray else { return nil }
        for i in 0..<sources.count {
            let src = sources.object(at: i) as AnyObject
            guard let libs = src.value(forKey: "libraryPlaylists") as? SBElementArray, libs.count > 0 else { continue }
            if let tracks = (libs.object(at: 0) as AnyObject).value(forKey: "tracks") as? SBElementArray, tracks.count > 0 {
                return tracks
            }
        }
        return nil
    }

    // MARK: Search (iTunes catalog)

    func search(_ query: String) async -> SearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .empty }
        async let songsTask = Self.catalogSongs(q)
        async let albumsTask = Self.catalogAlbums(q)
        var songs = await songsTask
        var albums = await albumsTask
        // Resolve the catalog hits against the saved library (pure-Swift match against
        // the loaded song list — reliable, no fragile per-search AppleScript). This
        // sets in-library status (drives the open-in-Music vs play UI), the real
        // favorited state (filled hearts), and the persistent ID so play/favorite
        // drive the exact saved track.
        let (songStatus, albumsInLibrary) = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: (self.resolveSongs(songs), self.resolveAlbums(albums))) }
        }
        songs = songs.map { s in
            guard let m = songStatus[s.id] else { return s }
            var x = s; x.inLibrary = true; x.libraryID = m.libraryID; x.isFavorited = m.favorited; return x
        }
        albums = albums.map { c in var x = c; x.inLibrary = albumsInLibrary.contains(c.id); return x }
        let lc = q.lowercased()
        let matching = await playlists().filter { $0.title.lowercased().contains(lc) }
        return SearchResults(topResults: Array(songs.prefix(3)), albums: albums, songs: songs, playlists: matching)
    }

    private static func catalogSongs(_ q: String) async -> [MusicSong] {
        let results = await itunes(term: q, entity: "song", limit: 25)
        return await withTaskGroup(of: (Int, MusicSong).self) { group in
            for (i, r) in results.enumerated() {
                group.addTask {
                    let art = await loadImage(r["artworkUrl100"] as? String)
                    return (i, MusicSong(
                        id: "sg:\((r["trackId"] as? NSNumber)?.stringValue ?? "\(i)")",
                        title: r["trackName"] as? String ?? "",
                        artist: r["artistName"] as? String ?? "",
                        album: r["collectionName"] as? String ?? "",
                        albumID: (r["collectionId"] as? NSNumber).map { "al:\($0.stringValue)" },
                        artwork: art,
                        duration: ((r["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                        inLibrary: false))   // resolved against the library in `search`
                }
            }
            var out: [(Int, MusicSong)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.title.isEmpty }
        }
    }

    private static func catalogAlbums(_ q: String) async -> [MusicCollection] {
        let results = await itunes(term: q, entity: "album", limit: 12)
        return await withTaskGroup(of: (Int, MusicCollection).self) { group in
            for (i, r) in results.enumerated() {
                group.addTask {
                    let art = await loadImage(r["artworkUrl100"] as? String)
                    let date = (r["releaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    return (i, MusicCollection(
                        id: "al:\((r["collectionId"] as? NSNumber)?.stringValue ?? "\(i)")", kind: .album,
                        title: r["collectionName"] as? String ?? "", subtitle: r["artistName"] as? String ?? "",
                        artwork: art, date: date, songs: [], inLibrary: false))   // resolved in `search`
                }
            }
            var out: [(Int, MusicCollection)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.title.isEmpty }
        }
    }

    private static func lookupAlbumTracks(collectionID cid: String) async -> [MusicSong] {
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")
        comps?.queryItems = [URLQueryItem(name: "id", value: cid), URLQueryItem(name: "entity", value: "song")]
        guard let url = comps?.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = (json?["results"] as? [[String: Any]]) ?? []
            let art = await loadImage(results.first?["artworkUrl100"] as? String)
            return results.filter { ($0["wrapperType"] as? String) == "track" }.compactMap { r in
                let title = r["trackName"] as? String ?? ""
                guard !title.isEmpty else { return nil }
                return MusicSong(id: "sg:\((r["trackId"] as? NSNumber)?.stringValue ?? UUID().uuidString)",
                                 title: title, artist: r["artistName"] as? String ?? "",
                                 album: r["collectionName"] as? String ?? "", albumID: "al:\(cid)", artwork: art,
                                 duration: ((r["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            }
        } catch { return [] }
    }

    private static func itunes(term: String, entity: String, limit: Int) async -> [[String: Any]] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [URLQueryItem(name: "term", value: term),
                             URLQueryItem(name: "entity", value: entity),
                             URLQueryItem(name: "limit", value: "\(limit)")]
        guard let url = comps?.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["results"] as? [[String: Any]]) ?? []
        } catch { return [] }
    }

    private static func loadImage(_ urlString: String?) async -> NSImage? {
        guard let urlString else { return nil }
        let large = urlString.replacingOccurrences(of: "100x100bb", with: "200x200bb")
        guard let url = URL(string: large) else { return nil }
        do { return NSImage(data: try await URLSession.shared.data(from: url).0) } catch { return nil }
    }

    // MARK: Actions (AppleScript drives the Music app)

    func play(_ collection: MusicCollection, shuffled: Bool) {
        if collection.id.hasPrefix("pl:") {
            let pid = Self.esc(String(collection.id.dropFirst(3)))
            runScript("""
            tell application "Music"
                set shuffle enabled to \(shuffled ? "true" : "false")
                try
                    play (some playlist whose persistent ID is "\(pid)")
                end try
            end tell
            """)
        } else if collection.id.hasPrefix("lal:") {
            // Library album (derived) — its id is "lal:<albumName>".
            playAlbum(title: String(collection.id.dropFirst(4)), artist: collection.subtitle,
                      shuffled: shuffled) { [self] in openInAppleMusic(collection: collection) }
        } else {
            // Catalog (Apple Music-wide) album. It may be in the user's library —
            // match it by title+artist and play it; only open in Music if it isn't.
            playAlbum(title: collection.title, artist: collection.subtitle,
                      shuffled: shuffled) { [self] in openInAppleMusic(collection: collection) }
        }
    }

    /// Play a library album located by Music's indexed `search` (the fast in-app
    /// search engine), starting from its lowest track number. Avoids
    /// `whose album is "…"`, which makes Music walk every track and beachballs large
    /// libraries (the reported freeze). Falls back to opening in Music when the album
    /// isn't in the library (catalog-only). `artist` is matched tolerantly so a
    /// catalog hit still resolves to the library copy.
    private func playAlbum(title: String, artist: String, shuffled: Bool, fallback: @escaping () -> Void) {
        guard !title.isEmpty else { fallback(); return }
        queue.async {
            let t = Self.esc(title)
            let a = Self.esc(artist)
            let source = """
            tell application "Music"
                set didPlay to "0"
                try
                    set hits to (search library playlist 1 for "\(t)" only albums)
                    set best to missing value
                    set bestNum to 1000000
                    repeat with h in hits
                        if (album of h) is "\(t)" then
                            if ("\(a)" is "") or ((album artist of h) contains "\(a)") or ((artist of h) contains "\(a)") or ("\(a)" contains (artist of h)) then
                                set n to (track number of h)
                                if n is 0 then set n to 999999
                                if n < bestNum then
                                    set bestNum to n
                                    set best to h
                                end if
                            end if
                        end if
                    end repeat
                    if best is not missing value then
                        set shuffle enabled to \(shuffled ? "true" : "false")
                        play best
                        set didPlay to "1"
                    end if
                end try
                return didPlay
            end tell
            """
            var error: NSDictionary?
            let played = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue == "1"
            if !played { DispatchQueue.main.async(execute: fallback) }
        }
    }

    func playSong(_ song: MusicSong) {
        if let lid = song.libraryID {
            playLibraryTrack(persistentID: lid)        // catalog hit resolved to a saved track
        } else if song.id.hasPrefix("sg:") {
            openInAppleMusic(song: song)               // catalog-only — not in the library
        } else {
            playLibraryTrack(persistentID: song.id)    // library-sourced song
        }
    }

    private func playLibraryTrack(persistentID pid: String) {
        runScript("""
        tell application "Music"
            try
                play (some track of library playlist 1 whose persistent ID is "\(Self.esc(pid))")
            end try
        end tell
        """)
    }

    func toggleFavorite(_ song: MusicSong) {
        // Only library tracks can be favorited via scripting. For a catalog hit that's
        // the resolved persistent ID; a catalog-only song (no libraryID) is a no-op.
        let pid: String? = song.libraryID ?? (song.id.hasPrefix("sg:") ? nil : song.id)
        guard let pid else { return }
        runScript("""
        tell application "Music"
            try
                set theTrack to (some track of library playlist 1 whose persistent ID is "\(Self.esc(pid))")
                set favorited of theTrack to (not (favorited of theTrack))
            end try
        end tell
        """)
    }

    func addToPlaylist(_ song: MusicSong, to playlist: MusicCollection) {}   // deferred (write)
    func openInAppleMusic(song: MusicSong) { AppleMusicLinks.openSong(title: song.title, artist: song.artist) }
    func openInAppleMusic(collection: MusicCollection) {
        AppleMusicLinks.openSong(title: collection.title, artist: collection.subtitle)
    }

    private func runScript(_ source: String) {
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    // MARK: KVC helpers

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    private static func firstArtwork(of obj: AnyObject) -> NSImage? {
        guard let arts = obj.value(forKey: "artworks") as? SBElementArray, arts.count > 0 else { return nil }
        return (arts.object(at: 0) as AnyObject).value(forKey: "data") as? NSImage
    }
    private static func artwork(in arr: SBElementArray, at index: Int) -> NSImage? {
        guard index >= 0, index < arr.count else { return nil }
        return firstArtwork(of: arr.object(at: index) as AnyObject)
    }
    /// Bulk-read a property column across an SBElementArray in one Apple Event.
    private static func stringColumn(_ arr: SBElementArray, _ key: String) -> [String] {
        (arr.value(forKey: key) as? [Any])?.map { $0 as? String ?? "" } ?? []
    }
    private static func doubleColumn(_ arr: SBElementArray, _ key: String) -> [Double] {
        (arr.value(forKey: key) as? [Any])?.map { ($0 as? NSNumber)?.doubleValue ?? 0 } ?? []
    }
    private static func boolColumn(_ arr: SBElementArray, _ key: String) -> [Bool] {
        (arr.value(forKey: key) as? [Any])?.map { ($0 as? NSNumber)?.boolValue ?? false } ?? []
    }
}
